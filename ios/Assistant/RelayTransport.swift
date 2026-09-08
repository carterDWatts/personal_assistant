import Foundation
import UIKit

struct RelayError: LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "conversation_busy": return "Busy answering on another device. Try again in a moment."
        case "invalid_request": return "Connecting from the phone isn’t available on the host yet."
        case "invalid_token": return "That token was not accepted."
        case "provider_unreachable": return "The service couldn’t be reached. Try again in a moment."
        case "account_denied", "device_denied": return "This phone isn’t allowed on the account."
        case "sign_in_required": return "Sign in again to continue."
        default: return "The host couldn’t be reached. Try again in a moment."
        }
    }
}

/// The conversation through the Supabase gateway: durable commands in, persisted events replayed in cursor order.
/// Polls while the app is in front; Realtime will replace the polling when the channel exists.
@MainActor final class RelayTransport: Transport {
    let events: AsyncStream<[String: Any]>
    private let emit: ([String: Any]) -> Void
    private let account = Account.shared
    private var cursor: Int64 = 0
    private var activeTurn: String?
    private var poller: Task<Void, Never>?
    private var inFront = true
    private var failures = 0

    init() {
        var continuation: AsyncStream<[String: Any]>.Continuation!
        events = AsyncStream { continuation = $0 }
        let yield = continuation!
        emit = { yield.yield($0) }
    }

    func connect(clear: Bool) {
        poller?.cancel()
        guard account.signedIn else { emit(["type": "status", "text": "Sign in to continue"]); return }
        Task { await bootstrap(clear: clear) }
    }

    private func bootstrap(clear: Bool) async {
        do {
            if clear {
                // A fresh segment on the host keeps the map and archives the messages, the same as the Mac.
                do { _ = try await call("clear", ["request_id": UUID().uuidString.lowercased()]) } catch let error as RelayError where error.code == "invalid_request" {
                    emit(["type": "status", "text": "Clearing isn’t available on the host yet"])
                }
            }
            if !account.registered {
                _ = try await call("register", ["name": UIDevice.current.name])
                account.registered = true
            }
            let boot = try await call("bootstrap")
            emit(["type": "history", "messages": boot["history"] as? [[String: Any]] ?? []])
            cursor = number(boot["replay_after"]) ?? number(boot["cursor"]) ?? 0
            activeTurn = (boot["active_turn"] as? [String: Any])?["turn_id"] as? String
            presence(boot["host"])
            if var day = boot["day"] as? [String: Any] { day["type"] = "map"; emit(day) }
            try await drain()
            if activeTurn == nil { emit(["type": "ready"]) } else { emit(["type": "status", "text": "Waiting for the host"]) }
            failures = 0
            poll()
        } catch {
            emit(["type": "error", "text": error.localizedDescription])
        }
    }

    private func presence(_ host: Any?) {
        guard let host = host as? [String: Any] else { return }
        if host["online"] as? Bool != true { emit(["type": "status", "text": "Host offline"]) }
    }

    private func drain() async throws {
        while true {
            let page = try await call("events", ["after": cursor])
            for envelope in page["events"] as? [[String: Any]] ?? [] {
                guard let next = number(envelope["cursor"]), next > cursor else { continue }
                cursor = next
                handle(envelope)
            }
            if page["has_more"] as? Bool != true { return }
        }
    }

    private func handle(_ envelope: [String: Any]) {
        guard var payload = envelope["payload"] as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "start":
            activeTurn = envelope["turn_id"] as? String
            emit(payload)
        case "end":
            activeTurn = nil
            emit(payload)
            emit(["type": "ready"])
        case "error":
            payload["text"] = payload["text"] ?? payload["message"]
            emit(payload)
        default:
            emit(payload)
        }
    }

    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            var sincePresence = 0
            while !Task.isCancelled {
                guard let self else { return }
                let busy = self.activeTurn != nil
                try? await Task.sleep(for: busy ? .milliseconds(250) : .seconds(3))
                guard !Task.isCancelled, self.inFront else { continue }
                do {
                    try await self.drain()
                    sincePresence += 1
                    if !busy && sincePresence >= 10 {
                        sincePresence = 0
                        let boot = try await self.call("bootstrap")
                        self.presence(boot["host"])
                        if self.activeTurn == nil, let turn = (boot["active_turn"] as? [String: Any])?["turn_id"] as? String {
                            self.activeTurn = turn
                        }
                    }
                    if self.failures >= 3 { self.emit(["type": "status", "text": "Connected"]) }
                    self.failures = 0
                } catch {
                    self.failures += 1
                    if self.failures == 3 { self.emit(["type": "status", "text": "Reconnecting…"]) }
                    if (error as? RelayError)?.status == 401 { self.emit(["type": "error", "text": error.localizedDescription]); return }
                }
            }
        }
    }

    func send(_ text: String, id: UUID) {
        Task {
            do {
                let result = try await call("submit", ["client_message_id": id.uuidString.lowercased(), "text": text])
                activeTurn = result["turn_id"] as? String
                try await drain()
            } catch {
                emit(["type": "error", "text": error.localizedDescription, "unsent": text])
            }
        }
    }

    func stop() {
        guard let turn = activeTurn else { return }
        Task { _ = try? await call("cancel", ["turn_id": turn]) }
    }

    func foreground(_ active: Bool) {
        inFront = active
        if active, poller != nil { Task { try? await drain() } }
    }

    func close() { poller?.cancel() }

    func connections() async throws -> [[String: Any]] {
        try await call("connections")["providers"] as? [[String: Any]] ?? []
    }

    func startConnection(provider: String, grant: String?) async throws -> (intent: String, url: URL?) {
        var args: [String: Any] = ["provider": provider]
        if let grant { args["grant"] = grant }
        let result = try await call("connection_start", args)
        guard let intent = result["intent_id"] as? String else { throw RelayError(status: 0, code: "invalid_request") }
        return (intent, (result["url"] as? String).flatMap(URL.init(string:)))
    }

    func connectionState(intent: String) async throws -> (state: String, error: String?) {
        let result = try await call("connection_status", ["intent_id": intent])
        return (result["state"] as? String ?? "pending", result["error"] as? String)
    }

    func connectToken(provider: String, token: String) async throws -> String {
        let result = try await call("connection_token", ["provider": provider, "token": token])
        return result["account"] as? String ?? Service.name(provider)
    }

    func removeConnection(provider: String, grant: String?) async throws {
        var args: [String: Any] = ["provider": provider]
        if let grant { args["grant"] = grant }
        _ = try await call("connection_remove", args)
    }

    private func number(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    private func call(_ action: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let token = try await account.accessToken()
        var request = URLRequest(url: Relay.url.appendingPathComponent("functions/v1/assistant"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(Relay.key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "device_id": account.deviceID, "args": args])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            if status == 401 { account.signOut() }
            throw RelayError(status: status, code: json["error"] as? String ?? "service_unavailable")
        }
        return json
    }
}
