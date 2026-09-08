import Foundation
import Security
import CryptoKit

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "assistant"

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    static func set(_ key: String, _ data: Data) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}

enum Relay {
    static let url = URL(string: "https://koauvyfxewczcajnlrfp.supabase.co")!
    static let key = "sb_publishable_Xdsr05lmo4XjfYRiT3qnBQ_r0CGUqiI"
}

struct AccountError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// The signed-in owner on this phone. Sign-in is a code sent to the account's email; the session lives in the Keychain.
@MainActor final class Account: ObservableObject {
    static let shared = Account()

    @Published private(set) var signedIn: Bool
    @Published var problem = ""
    let deviceID: String
    private var session: Session? {
        didSet {
            if let session, let data = try? JSONEncoder().encode(session) { Keychain.set("session", data) } else { Keychain.delete("session") }
            signedIn = session != nil
        }
    }
    private struct Session: Codable {
        var accessToken, refreshToken: String
        var expiresAt: Date
    }

    private init() {
        if let stored = Keychain.get("device"), let id = String(data: stored, encoding: .utf8) {
            deviceID = id
        } else {
            deviceID = UUID().uuidString.lowercased()
            Keychain.set("device", Data(deviceID.utf8))
        }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["ASSISTANT_VOICE_TEST"] == "1" {
            let fixture = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("replay-session.json")
            if let data = try? Data(contentsOf: fixture), (try? JSONDecoder().decode(Session.self, from: data)) != nil {
                Keychain.set("session", data)
                try? FileManager.default.removeItem(at: fixture)
            }
        }
        #endif
        session = Keychain.get("session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        signedIn = session != nil
    }

    var registered: Bool {
        get { UserDefaults.standard.bool(forKey: "registered:" + deviceID) }
        set { UserDefaults.standard.set(newValue, forKey: "registered:" + deviceID) }
    }

    /// Where the link in the sign-in email brings the phone back. The Auth project allowlists it.
    static let callback = "personal-assistant://auth/callback"

    /// Kept in the Keychain because the link is usually tapped after the app has been closed.
    private var verifier: String? {
        get { Keychain.get("verifier").flatMap { String(data: $0, encoding: .utf8) } }
        set { if let newValue { Keychain.set("verifier", Data(newValue.utf8)) } else { Keychain.delete("verifier") } }
    }

    func requestLink(email: String) async throws {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AccountError("Couldn’t start sign-in.") }
        let verifier = base64url(Data(bytes))
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.verifier = verifier
        let redirect = Self.callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? Self.callback
        _ = try await auth("otp?redirect_to=" + redirect,
                           ["email": email, "create_user": false, "code_challenge": challenge, "code_challenge_method": "s256"])
    }

    /// The link lands here, on a running app or one launched by it. The code is exchanged with Auth; the link alone proves nothing.
    func open(_ url: URL) async {
        guard url.scheme == "personal-assistant", url.host == "auth" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let description = items.first(where: { $0.name == "error_description" })?.value {
            problem = description.replacingOccurrences(of: "+", with: " "); return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { problem = "The link didn’t carry a sign-in code."; return }
        guard let verifier else { problem = "Ask for a new link from this phone."; return }
        do {
            session = try parse(await auth("token?grant_type=pkce", ["auth_code": code, "code_verifier": verifier]))
            self.verifier = nil
            problem = ""
        } catch {
            problem = error.localizedDescription
        }
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A token good for at least another minute, refreshed here when it is not.
    func accessToken() async throws -> String {
        guard let current = session else { throw AccountError("Sign in to continue.") }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        do {
            let refreshed = try parse(await auth("token?grant_type=refresh_token", ["refresh_token": current.refreshToken]))
            session = refreshed
            return refreshed.accessToken
        } catch let error as URLError {
            throw error
        } catch {
            session = nil
            throw AccountError("Sign in again to continue.")
        }
    }

    func signOut() { session = nil }

    private func parse(_ json: [String: Any]) throws -> Session {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw AccountError("The sign-in reply was incomplete.")
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }

    private func auth(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Relay.url.absoluteString + "/auth/v1/" + path) else { throw AccountError("Bad sign-in address.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(Relay.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AccountError(json["msg"] as? String ?? json["error_description"] as? String ?? "Sign-in failed (\(status)).")
        }
        return json
    }
}
