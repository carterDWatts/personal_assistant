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

/// What a reply needed and did not have, with the request that hit the wall.
struct ConnectionPrompt {
    let action: String
    let provider: String
    let grant: String?
    let request: String?
    var phase = Phase.needed
    enum Phase: Equatable { case needed, connecting, connected, failed(String) }

    init(event: [String: Any], request: String?) {
        let action = event["action"] as? String ?? ""
        self.action = action
        provider = event["provider"] as? String ?? Service.provider(for: action)
        grant = event["grant"] as? String ?? Service.grant(for: action)
        self.request = request
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
        default: return provider.capitalized
        }
    }

    static func usesToken(_ provider: String) -> Bool { provider != "google" }

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

/// Runs the host's Google authorization in the system sheet and returns when the callback lands.
@MainActor final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuth()
    private var session: ASWebAuthenticationSession?

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "personal-assistant") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? URLError(.cancelled)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
