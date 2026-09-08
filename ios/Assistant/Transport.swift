import Foundation
import AVFoundation

/// The engine as the phone sees it: commands in, the bridge event vocabulary out.
/// Events are the same payloads the Mac reads (history, ready, start, delta, replace, end, memory, map, status, error).
@MainActor protocol Transport: AnyObject {
    var events: AsyncStream<[String: Any]> { get }
    func connect(clear: Bool)
    func send(_ text: String, id: UUID, speech: Bool, model: String?, mode: String)
    func stop()
    func foreground(_ active: Bool)
    func close()
    /// Connection setup for the host. Credentials go only through these, never through send.
    func importPart(_ args: [String: Any]) async throws
    func imports() async throws -> [[String: Any]]
    func connections() async throws -> [[String: Any]]
    func startConnection(provider: String, grant: String?) async throws -> (intent: String, url: URL?)
    func connectionState(intent: String) async throws -> (state: String, error: String?)
    func connectToken(provider: String, token: String) async throws -> String
    func removeConnection(provider: String, grant: String?) async throws
}

func isoDate(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Answers from a script, so the interface can be built and used before the relay exists.
@MainActor final class MockTransport: Transport {
    let events: AsyncStream<[String: Any]>
    private let emit: ([String: Any]) -> Void
    private var reply: Task<Void, Never>?
    private var turn = 0
    private var history: [[String: Any]] = []
    private static let answers = [
        "Morning. Nothing is on the calendar until the afternoon, so the dentist call is the one thing worth doing before lunch.",
        "That fits. I’ll keep it in the plan for today, and I can bring it up again tomorrow if it slips.",
        "I don’t know that yet. Tell me when it comes up and I’ll keep track of it.",
    ]

    init() {
        var continuation: AsyncStream<[String: Any]>.Continuation!
        events = AsyncStream { continuation = $0 }
        let yield = continuation!
        emit = { yield.yield($0) }
        if ProcessInfo.processInfo.arguments.contains("--sample") {
            let yesterday = Date().addingTimeInterval(-86_400)
            history = [["role": "user", "content": "Car is in the garage on level two.", "created_at": isoDate(yesterday)],
                       ["role": "assistant", "content": "Got it, level two. I’ll remember that.", "created_at": isoDate(yesterday)],
                       ["role": "user", "content": "What should I get done before lunch?", "created_at": isoDate(Date())],
                       ["role": "assistant", "content": Self.answers[0], "created_at": isoDate(Date())]]
        }
    }

    func connect(clear: Bool) {
        if clear { history = [] }
        emit(["type": "history", "messages": history])
        emit(["type": "status", "text": "Connecting…"])
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            emit(["type": "capabilities", "speech": true])
            emit(["type": "ready"])
            emit(map())
            if ProcessInfo.processInfo.arguments.contains("--connection") {
                emit(["type": "connection_required", "action": "google_connect", "message": "This service needs to be connected on this host."])
            }
        }
    }

    func send(_ text: String, id: UUID, speech: Bool, model: String?, mode: String) {
        history.append(["role": "user", "content": text, "created_at": isoDate(Date())])
        reply?.cancel()
        let answer = Self.answers[turn % Self.answers.count]
        turn += 1
        let turnID = UUID().uuidString.lowercased()
        emit(["type": "submitted", "turn_id": turnID, "speech": speech])
        reply = Task { [weak self] in
            guard let self else { return }
            emit(["type": "start", "turn_id": turnID])
            try? await Task.sleep(for: .milliseconds(700))
            if text.lowercased().contains("calendar") && (linked["google"] ?? []).isEmpty {
                emit(["type": "connection_required", "action": "google_connect", "message": "This service needs to be connected on this host."])
            }
            var spoken = ""
            for word in answer.split(separator: " ") {
                if Task.isCancelled { break }
                let piece = (spoken.isEmpty ? "" : " ") + word
                spoken += piece
                emit(["type": "delta", "text": piece])
                try? await Task.sleep(for: .milliseconds(45))
            }
            if !Task.isCancelled { emit(["type": "replace", "text": spoken]) }
            if speech {
                var rest = spoken, seq = 0
                while let chunk = nextSpeechChunk(&rest, flush: true), !Task.isCancelled {
                    seq += 1
                    if let file = await Self.render(chunk) {
                        emit(["type": "speech", "turn_id": turnID, "seq": seq, "url": file.absoluteString, "text": chunk])
                    }
                }
                emit(["type": "speech_end", "turn_id": turnID, "status": "success"])
            }
            history.append(["role": "assistant", "content": spoken, "created_at": isoDate(Date())])
            emit(["type": "end"])
            emit(["type": "ready"])
            emit(map())
        }
    }

    func stop() { reply?.cancel() }
    func foreground(_ active: Bool) {}
    func close() { reply?.cancel() }

    private var linked: [String: [String]] = [:]

    func connections() async throws -> [[String: Any]] {
        ["google", "todoist", "notion", "github"].map { provider in
            ["id": provider, "kind": provider == "google" ? "google" : "token",
             "state": (linked[provider] ?? []).isEmpty ? "absent" : "connected", "grants": linked[provider] ?? [],
             "account": (linked[provider] ?? []).isEmpty ? nil : "sample account"] as [String: Any]
        }
    }

    func startConnection(provider: String, grant: String?) async throws -> (intent: String, url: URL?) {
        try await Task.sleep(for: .seconds(1))
        linked[provider, default: []].append(grant ?? provider)
        emit(["type": "connections", "providers": try await connections()])
        return ("sample", nil)
    }

    func connectionState(intent: String) async throws -> (state: String, error: String?) { ("connected", nil) }

    func connectToken(provider: String, token: String) async throws -> String {
        try await Task.sleep(for: .seconds(1))
        guard token.count > 8 else { throw MockError("That token was not accepted.") }
        linked[provider] = [provider]
        emit(["type": "connections", "providers": try await connections()])
        return "sample account"
    }

    func removeConnection(provider: String, grant: String?) async throws {
        linked[provider] = nil
        emit(["type": "connections", "providers": try await connections()])
    }

    /// Stands in for the host's synthesizer by writing one chunk to a file the way the host will serve one.
    private static func render(_ text: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = LiveVoice.voice
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            var file: AVAudioFile?
            var resumed = false
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !resumed { resumed = true; continuation.resume(returning: file == nil ? nil : url) }
                    return
                }
                if file == nil { file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                try? file?.write(from: pcm)
            }
            _ = synthesizer
        }
    }

    private func map() -> [String: Any] {
        ["type": "map",
         "plans": [["item": "Call the dentist about Thursday", "status": "planned"],
                   ["item": "Walk before it gets hot", "status": "done"],
                   ["item": "Look over the phone client", "status": "proposed"]],
         "questions": 1, "pending": 0, "errors": 0]
    }
}

struct MockError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

@MainActor extension Transport {
    func importPart(_ args: [String: Any]) async throws { throw ConnectionFailure("Imports are unavailable in preview.") }
    func imports() async throws -> [[String: Any]] { [] }
}
