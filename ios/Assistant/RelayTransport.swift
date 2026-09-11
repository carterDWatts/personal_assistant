import Foundation
import UIKit

struct RelayError: LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "conversation_busy": return "Busy answering on another device. Try again in a moment."
        case "invalid_request": return "That request could not be completed. Try again."
        case "model_unavailable": return "That model isn’t available on this host. Choose another model."
        case "voice_unavailable": return "Choose an available voice in Settings."
        case "speech_unavailable": return "The host voice is starting. Reconnect in a moment."
        case "connections_unavailable": return "Connections are temporarily unavailable. Try again shortly."
        case "connection_rejected": return "Access wasn’t granted. Check the permissions and try connecting again."
        case "invalid_token": return "That token was not accepted."
        case "provider_unreachable": return "The service couldn’t be reached. Try again in a moment."
        case "account_denied", "device_denied": return "This phone isn’t allowed on the account."
        case "sign_in_required": return "Sign in again to continue."
        default: return "The host couldn’t be reached. Try again in a moment."
        }
    }
}

/// The conversation through the Supabase gateway: durable commands in, persisted events replayed in cursor order.
/// A live socket waits for events at the gateway; HTTP polling remains the reconnect fallback.
@MainActor final class RelayTransport: Transport {
    let events: AsyncStream<[String: Any]>
    private let emit: ([String: Any]) -> Void
    private let account = Account.shared
    private var cursor: Int64 = 0
    private var activeTurn: String?
    private var audioTurn: String?
    private var poller: Task<Void, Never>?
    private var inFront = true
    private var failures = 0
    private var replaying = false
    private var draining = false
    private var playerGeneration = 0
    private let socket = RelaySocket()
    var socketResponses: Int { socket.responses }

    init() {
        var continuation: AsyncStream<[String: Any]>.Continuation!
        events = AsyncStream { continuation = $0 }
        let yield = continuation!
        emit = { yield.yield($0) }
    }

    func connect(clear: Bool) {
        playerGeneration += 1
        Spotify.shared.cancel()
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
            var capabilities = boot["capabilities"] as? [String: Any] ?? [:]
            capabilities["type"] = "capabilities"; emit(capabilities)
            if var day = boot["day"] as? [String: Any] { day["type"] = "map"; emit(day) }
            replaying = true
            try await drain()
            replaying = false
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
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while true {
            let page = try await call("events", ["after": cursor, "wait": !replaying && (activeTurn != nil || audioTurn != nil)])
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
        payload["turn_id"] = envelope["turn_id"]
        switch type {
        case "start":
            activeTurn = envelope["turn_id"] as? String
            emit(payload)
        case "end":
            if let current = activeTurn, let ended = envelope["turn_id"] as? String, current != ended { return }
            activeTurn = nil
            emit(payload)
            emit(["type": "ready"])
        case "error":
            payload["text"] = payload["text"] ?? payload["message"]
            emit(payload)
        case "speech", "speech_end":
            // Audio is for the live turn only; a reconnect keeps the text and skips the sound.
            if !replaying { payload["turn_id"] = envelope["turn_id"]; emit(payload) }
            if type == "speech_end", envelope["turn_id"] as? String == audioTurn { audioTurn = nil }
        case "spotify_command":
            guard !replaying, payload["device_id"] as? String == account.deviceID,
                  let command = payload["command_id"] as? String else { return }
            let generation = playerGeneration
            let turn = activeTurn
            Task {
                do {
                    let claimed = try await call("spotify_command", ["action": "claim", "command_id": command])
                    guard claimed["state"] as? String == "ready", let args = claimed["command"] as? [String: Any],
                          let client = claimed["client_id"] as? String,
                          playerGeneration == generation, activeTurn == turn, turn != nil else { return }
                    emit(["type": "spotify_control", "action": args["action"] as? String ?? ""])
                    let result = await Spotify.shared.run(args, clientID: client)
                    // Only the receipt is retried. Never repeat the player command.
                    for attempt in 0..<3 {
                        do { _ = try await call("spotify_command", ["action": "finish", "command_id": command, "result": result]); break }
                        catch { if attempt < 2 { try? await Task.sleep(for: .seconds(1)) } }
                    }
                } catch { emit(["type": "status", "text": "Spotify control could not connect."]) }
            }
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
                let busy = self.activeTurn != nil || self.audioTurn != nil
                // A submitted turn must wake an idle poll immediately.
                for _ in 0..<(busy ? 1 : 60) {
                    try? await Task.sleep(for: .milliseconds(busy ? 10 : 50))
                    if Task.isCancelled { return }
                    if !busy && (self.activeTurn != nil || self.audioTurn != nil) { break }
                }
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

    func send(_ text: String, id: UUID, speech: Bool, model: String?, mode: String, notification: [String: String]?) {
        submit(text, id: id, speech: speech, model: model, mode: mode, notification: notification, images: [])
    }
    func sendImages(_ text: String, id: UUID, model: String?, images: [String]) {
        submit(text, id: id, speech: false, model: model, mode: "talk", notification: nil, images: images)
    }
    private func submit(_ text: String, id: UUID, speech: Bool, model: String?, mode: String, notification: [String: String]?, images: [String]) {
        Task {
            do {
                var args: [String: Any] = ["client_message_id": id.uuidString.lowercased(), "text": text, "images": images]
                args["mode"] = mode
                if let notification { args["notification"] = notification }
                if speech {
                    args["speech"] = true
                    if let voice = UserDefaults.standard.string(forKey: "hostedVoice"), !voice.isEmpty { args["voice"] = voice }
                }
                if let model, !model.isEmpty { args["model"] = model }
                VoiceDiagnostics.record("request_started")
                let started = Date()
                let routine = ["morning", "review"].contains(mode)
                if routine { args["kind"] = mode; args.removeValue(forKey: "mode") }
                let result = try await call(routine ? "start_routine" : "submit", args)
                VoiceDiagnostics.record("request_accepted", ["seconds": Date().timeIntervalSince(started)])
                #if DEBUG
                print("Submit round trip:", Date().timeIntervalSince(started))
                #endif
                activeTurn = result["turn_id"] as? String
                if speech { audioTurn = activeTurn }
                if let turn = activeTurn { emit(["type": "submitted", "turn_id": turn, "speech": speech]) }
                try await drain()
            } catch {
                emit(["type": "error", "text": error.localizedDescription, "unsent": text])
            }
        }
    }

    func stop() {
        playerGeneration += 1
        Spotify.shared.cancel()
        guard let turn = activeTurn ?? audioTurn else { return }
        audioTurn = nil
        Task { _ = try? await call("cancel", ["turn_id": turn]) }
    }

    func foreground(_ active: Bool) {
        inFront = active
        if !active { socket.close() }
        if active, poller != nil { Task { try? await drain() } }
    }

    func close() { playerGeneration += 1; poller?.cancel(); socket.close(); Spotify.shared.cancel() }

    func reminderRequest(_ action: String, _ args: [String: Any]) async throws -> [String: Any] { try await call(action, args) }
    func importPart(_ args: [String: Any]) async throws { _ = try await call("import_part", args) }
    func imports() async throws -> [[String: Any]] { try await call("imports")["imports"] as? [[String: Any]] ?? [] }

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
        if provider == "spotify" { Spotify.shared.disconnect() }
    }

    private func number(_ value: Any?) -> Int64? {
        switch value {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    func clientRequest(_ action: String, _ args: [String: Any]) async throws -> [String: Any] { try await call(action, args) }

    private func call(_ action: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let token = try await account.accessToken()
        let input: [String: Any] = ["action": action, "device_id": account.deviceID, "args": args]
        if ["register", "bootstrap", "submit", "cancel", "events", "clear"].contains(action) {
            do {
                let (status, body) = try await socket.request(input, token: token)
                guard (200..<300).contains(status) else { throw RelayError(status: status, code: body["error"] as? String ?? "service_unavailable") }
                return body
            } catch let error as RelayError {
                if error.status == 401 { account.signOut() }
                throw error
            }
            catch { /* Replay-safe HTTP fallback while the persistent connection recovers. */ }
        }
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
