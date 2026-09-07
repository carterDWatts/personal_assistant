import Foundation

// Stop playback on tentative speech; cancel generation only for a complete utterance.
struct VoiceTurn {
    private(set) var interrupted = false
    private(set) var pending: String?
    private var cancellationRequested = false

    mutating func pausePlayback(busy: Bool) {
        if busy { interrupted = true }
    }

    mutating func interrupt(busy: Bool) -> Bool {
        guard busy, !cancellationRequested else { return false }
        interrupted = true; cancellationRequested = true
        return true
    }

    mutating func queue(_ text: String) {
        pending = [pending, text].compactMap { $0 }.joined(separator: " ")
    }

    mutating func discardPending() { pending = nil }

    mutating func ready() -> String? {
        interrupted = false; cancellationRequested = false
        defer { pending = nil }
        return pending
    }
}
