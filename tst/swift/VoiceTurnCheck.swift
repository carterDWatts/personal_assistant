import Foundation

@main struct VoiceTurnCheck {
    static func main() {
        var turn = VoiceTurn()
        precondition(!turn.interrupt(busy: false))
        precondition(turn.interrupt(busy: true))
        precondition(!turn.interrupt(busy: true))
        turn.queue("Actually")
        turn.queue("make it tomorrow")
        precondition(turn.interrupted)
        precondition(turn.ready() == "Actually make it tomorrow")
        precondition(!turn.interrupted && turn.pending == nil)
        precondition(turn.ready() == nil)
        precondition(turn.interrupt(busy: true))
        turn.queue("discard this when voice ends")
        turn.discardPending()
        precondition(turn.ready() == nil)
        // A provisional recognition must not consume the cancellation request.
        turn.pausePlayback(busy: true)
        precondition(turn.interrupted && turn.pending == nil)
        precondition(turn.ready() == nil)
        precondition(!turn.interrupted)
        turn.pausePlayback(busy: true)
        turn.pausePlayback(busy: true)
        turn.queue("What is the bicycle name?")
        precondition(turn.interrupt(busy: true))
        precondition(!turn.interrupt(busy: true))
        precondition(turn.ready() == "What is the bicycle name?")
        var incomplete = "This is still"
        precondition(nextSpeechChunk(&incomplete, flush: false) == nil)
        precondition(incomplete == "This is still")
        let original = String(repeating: "A longer spoken reply has several words ", count: 8) + "."
        var buffer = original
        var chunks: [String] = []
        while let chunk = nextSpeechChunk(&buffer, flush: true) { chunks.append(chunk) }
        precondition(chunks.first!.count <= 100)
        precondition(chunks.joined() == original)
        precondition(nextSpeechChunk(&incomplete, flush: true) == "This is still")
        precondition(incomplete.isEmpty)
        print("Voice interruption preserves speech and cancels each turn once.")
    }
}
