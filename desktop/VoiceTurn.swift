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

// Catch residual speaker echo after acoustic cancellation, including delayed ASR results.
struct PlaybackEcho {
    private var words: [String] = []
    private var playing = false
    private var endedAt = Date.distantPast

    private func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    mutating func record(_ text: String, now: Date = Date()) {
        if !playing && now.timeIntervalSince(endedAt) > 2 { words.removeAll() }
        words = Array((words + tokens(text)).suffix(100))
        playing = true
    }

    mutating func resumed() { playing = true }

    mutating func finished(now: Date = Date()) {
        if playing { endedAt = now; playing = false }
    }

    func matches(_ text: String, now: Date = Date()) -> Bool {
        guard playing || now.timeIntervalSince(endedAt) <= 2 else { return false }
        let heard = tokens(text)
        guard !heard.isEmpty, heard.count <= words.count else { return false }
        // Short fragments must match exactly; longer ones tolerate one ASR substitution.
        let tolerance = heard.count >= 5 ? 1 : 0
        return (0...(words.count - heard.count)).contains { start in
            zip(heard, words[start..<(start + heard.count)]).filter { $0 != $1 }.count <= tolerance
        }
    }
}
