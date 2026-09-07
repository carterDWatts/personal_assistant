import Foundation

// Keep cancelled output out of playback until the engine acknowledges the turn ending.
struct VoiceTurn {
    private(set) var interrupted = false
    private(set) var pending: String?

    mutating func interrupt(busy: Bool) -> Bool {
        guard busy, !interrupted else { return false }
        interrupted = true
        return true
    }

    mutating func queue(_ text: String) {
        pending = [pending, text].compactMap { $0 }.joined(separator: " ")
    }

    mutating func discardPending() { pending = nil }

    mutating func ready() -> String? {
        interrupted = false
        defer { pending = nil }
        return pending
    }
}
