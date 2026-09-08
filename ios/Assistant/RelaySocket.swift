import Foundation

@MainActor final class RelaySocket {
    private(set) var responses = 0
    private var socket: URLSessionWebSocketTask?
    private var tokenAtOpen: String?
    private var receiver: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<(Int, [String: Any]), Error>] = [:]

    func request(_ input: [String: Any], token: String) async throws -> (Int, [String: Any]) {
        if tokenAtOpen != token { close() }
        if socket == nil { open(token: token) }
        guard let socket else { throw URLError(.cannotConnectToHost) }
        let id = UUID().uuidString
        var payload = input; payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        let message = String(decoding: data, as: UTF8.self)
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.pending[id] != nil else { return }
            self.close()
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await socket.send(.string(message)) }
                catch { if self.socket === socket { self.close() } }
            }
        }
    }

    private func open(token: String) {
        var components = URLComponents(url: Relay.url.appendingPathComponent("functions/v1/assistant"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(Relay.key, forHTTPHeaderField: "apikey")
        let connection = URLSession.shared.webSocketTask(with: request)
        connection.maximumMessageSize = 10_000_000
        socket = connection
        tokenAtOpen = token
        connection.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: throw URLError(.cannotParseResponse)
                    }
                    guard let self, self.socket === connection else { return }
                    let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let id = result?["id"] as? String, let status = result?["status"] as? Int,
                          let body = result?["body"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
                    self.responses += 1
                    self.pending.removeValue(forKey: id)?.resume(returning: (status, body))
                }
            } catch {
                guard let self, self.socket === connection else { return }
                self.close()
            }
        }
    }

    func close() {
        receiver?.cancel(); receiver = nil
        tokenAtOpen = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: URLError(.networkConnectionLost)) }
    }
}
