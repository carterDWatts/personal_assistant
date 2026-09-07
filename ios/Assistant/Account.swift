import Foundation
import Security

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
        session = Keychain.get("session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        signedIn = session != nil
    }

    var registered: Bool {
        get { UserDefaults.standard.bool(forKey: "registered:" + deviceID) }
        set { UserDefaults.standard.set(newValue, forKey: "registered:" + deviceID) }
    }

    func requestCode(email: String) async throws {
        _ = try await auth("otp", ["email": email, "create_user": false])
    }

    func verify(email: String, code: String) async throws {
        session = try parse(await auth("verify", ["type": "email", "email": email, "token": code]))
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
        var request = URLRequest(url: Relay.url.appendingPathComponent("auth/v1/" + path))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(Relay.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AccountError(json["msg"] as? String ?? json["error_description"] as? String ?? "Sign-in failed.")
        }
        return json
    }
}
