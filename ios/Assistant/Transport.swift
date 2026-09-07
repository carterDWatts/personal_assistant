import Foundation

/// The engine as the phone sees it: commands in, the bridge event vocabulary out.
/// Events are the same payloads the Mac reads (history, ready, start, delta, replace, end, memory, map, status, error).
@MainActor protocol Transport: AnyObject {
    var events: AsyncStream<[String: Any]> { get }
    func connect(clear: Bool)
    func send(_ text: String, id: UUID)
    func stop()
    func close()
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
            emit(["type": "ready"])
            emit(map())
        }
    }

    func send(_ text: String, id: UUID) {
        history.append(["role": "user", "content": text, "created_at": isoDate(Date())])
        reply?.cancel()
        let answer = Self.answers[turn % Self.answers.count]
        turn += 1
        reply = Task { [weak self] in
            guard let self else { return }
            emit(["type": "start"])
            try? await Task.sleep(for: .milliseconds(700))
            var spoken = ""
            for word in answer.split(separator: " ") {
                if Task.isCancelled { break }
                let piece = (spoken.isEmpty ? "" : " ") + word
                spoken += piece
                emit(["type": "delta", "text": piece])
                try? await Task.sleep(for: .milliseconds(45))
            }
            if !Task.isCancelled { emit(["type": "replace", "text": spoken]) }
            history.append(["role": "assistant", "content": spoken, "created_at": isoDate(Date())])
            emit(["type": "end"])
            emit(["type": "ready"])
            emit(map())
        }
    }

    func stop() { reply?.cancel() }
    func close() { reply?.cancel() }

    private func map() -> [String: Any] {
        ["type": "map",
         "plans": [["item": "Call the dentist about Thursday", "status": "planned"],
                   ["item": "Walk before it gets hot", "status": "done"],
                   ["item": "Look over the phone client", "status": "proposed"]],
         "questions": 1, "pending": 0, "errors": 0]
    }
}
