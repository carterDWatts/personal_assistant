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

    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        kind = row["kind"] as? String ?? (id == "google" ? "google" : "token")
        state = row["state"] as? String ?? "absent"
        grants = row["grants"] as? [String] ?? []
        account = row["account"] as? String
    }
}

/// A missing connection offered directly in the conversation.
struct ConnectionPrompt {
    let action: String
    let sessionID: String?
    let provider: String
    let grant: String?
    var phase = Phase.needed
    enum Phase: Equatable { case needed, connecting, failed(String) }

    init(event: [String: Any]) {
        let action = event["action"] as? String ?? ""
        self.action = action
        sessionID = event["session_id"] as? String
        provider = event["provider"] as? String ?? Service.provider(for: action)
        grant = event["grant"] as? String ?? Service.grant(for: action)
    }
}

/// Names and setup copy for each service. The token services are guided setup, not sign-in.
enum Service {
    static func provider(for action: String) -> String {
        if action.hasPrefix("google") { return "google" }
        return action.replacingOccurrences(of: "_connect", with: "")
    }

    static func grant(for action: String) -> String? {
        switch action {
        case "google_connect": return "calendar"
        case "google_calendar_write": return "calendar_write"
        case "google_tasks": return "tasks"
        case "google_drive": return "drive"
        case "google_contacts": return "contacts"
        default: return nil
        }
    }

    static func name(_ provider: String, grant: String? = nil) -> String {
        switch (provider, grant) {
        case ("google", "tasks"): return "Google Tasks"
        case ("google", "drive"): return "Drive, Docs and Sheets"
        case ("google", "contacts"): return "Google Contacts"
        case ("google", "calendar_write"): return "Calendar changes"
        case ("google", _): return "Google Calendar and Gmail"
        case ("todoist", _): return "Todoist"
        case ("notion", _): return "Notion"
        case ("github", _): return "GitHub"
        case ("supabase", _): return "Supabase"
        default: return provider.capitalized
        }
    }

    static func usesToken(_ provider: String) -> Bool { !["google", "github", "supabase"].contains(provider) }

    static func instructions(_ provider: String) -> String {
        switch provider {
        case "todoist": return "In Todoist, open Settings › Integrations › Developer and copy the API token. The assistant only reads active tasks, due dates and deadlines."
        case "notion": return "In Notion, create an internal connection with Read content, share the pages you want it to see, and paste its secret. The assistant only searches titles and reads shared pages."
        case "github": return "On GitHub, create a fine-grained personal access token for the repositories you want, with read access to Issues and Pull requests, and paste it. The assistant only reads issues and pull requests."
        default: return ""
        }
    }

    static let grants = ["calendar", "calendar_write", "tasks", "drive", "contacts"]
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
