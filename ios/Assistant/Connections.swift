import Foundation
import AuthenticationServices
import UIKit

/// A service the host can read from, as the host reports it.
struct Connection: Identifiable {
    let id: String
    var kind: String
    var state: String
    var grants: [String]
    var account: String?
    var configured: Bool
    var capabilities: [String]

    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        kind = row["kind"] as? String ?? (IntegrationCatalog.find(id)?.auth ?? "unavailable")
        state = row["state"] as? String ?? "absent"
        grants = row["grants"] as? [String] ?? []
        account = row["account"] as? String
        configured = row["configured"] as? Bool ?? true
        capabilities = row["capabilities"] as? [String] ?? []
    }
}

/// A missing connection offered directly in the conversation.
struct ConnectionPrompt {
    let id = UUID()
    let action: String
    let provider: String
    let grant: String?
    var phase = Phase.needed
    enum Phase: Equatable { case needed, connecting, failed(String) }

    init(event: [String: Any]) {
        let action = event["action"] as? String ?? ""
        self.action = action
        provider = event["provider"] as? String ?? Service.provider(for: action)
        grant = event["grant"] as? String ?? Service.grant(for: action)
    }
}

/// Presentation helpers backed by the same catalog as the gateway and host.
enum Service {
    static func provider(for action: String) -> String { IntegrationCatalog.provider(for: action) ?? "" }
    static func grant(for action: String) -> String? { IntegrationCatalog.grant(for: action) }
    static func name(_ provider: String, grant: String? = nil) -> String { IntegrationCatalog.name(provider, grant: grant) }
    static func usesToken(_ provider: String) -> Bool { IntegrationCatalog.find(provider)?.auth == "token" }
    static func instructions(_ provider: String) -> String { IntegrationCatalog.find(provider)?.instructions ?? "" }
    static var grants: [String] { IntegrationCatalog.googleGrants.map(\.id) }
}

/// Prefer an installed app's verified universal link, then the system sign-in sheet.
@MainActor final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuth()
    private var session: ASWebAuthenticationSession?
    private var completion: CheckedContinuation<URL, Error>?
    private var attempt: UUID?
    private var native = false

    func run(_ url: URL) async throws -> URL {
        guard completion == nil, url.scheme == "https" else { throw URLError(.badURL) }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); attempt = id; completion = continuation; native = true
            Task { @MainActor in
                let opened = await UIApplication.shared.open(url, options: [.universalLinksOnly: true])
                guard attempt == id else { return }
                if !opened {
                    native = false
                    let sheet = ASWebAuthenticationSession(url: url, callbackURLScheme: "personal-assistant") { callback, error in
                        Task { @MainActor in
                            guard self.attempt == id else { return }
                            self.finish(callback.map(Result.success) ?? .failure(error ?? URLError(.cancelled)))
                        }
                    }
                    sheet.presentationContextProvider = self
                    sheet.prefersEphemeralWebBrowserSession = false
                    session = sheet
                    if !sheet.start() { finish(.failure(URLError(.cannotConnectToHost))); return }
                }
                try? await Task.sleep(for: .seconds(180))
                if attempt == id { finish(.failure(URLError(.timedOut))) }
            }
        }
    }

    /// This only wakes the flow. Chat verifies the original intent with the host.
    func receive(_ url: URL) -> Bool {
        guard native, completion != nil, url.scheme == "personal-assistant", url.host == "connection" else { return false }
        finish(.success(url)); return true
    }

    private func finish(_ result: Result<URL, Error>) {
        let pending = completion
        completion = nil; attempt = nil; native = false
        let sheet = session; session = nil; sheet?.cancel()
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
