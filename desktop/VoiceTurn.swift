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

// Bound synthesis work before the first audio without cutting words apart.
func nextSpeechChunk(_ buffer: inout String, flush: Bool) -> String? {
    let prefix = buffer.prefix(100)
    let punctuation = buffer.firstIndex(where: { ".!?\n".contains($0) })
    let clause = prefix.count >= 40 ? prefix.firstIndex(where: { ",;:".contains($0) }) : nil
    let limit = prefix.count == 100 ? prefix.lastIndex(where: { $0.isWhitespace }) : nil
    if let end = [punctuation, clause, limit].compactMap({ $0 }).min() {
        let next = buffer.index(after: end)
        let chunk = String(buffer[..<next]); buffer.removeSubrange(..<next)
        return chunk
    }
    guard flush, !buffer.isEmpty else { return nil }
    let chunk = buffer; buffer = ""
    return chunk
}
