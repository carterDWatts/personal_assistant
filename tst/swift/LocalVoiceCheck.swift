import Foundation

@main struct LocalVoiceCheck {
    @MainActor static func main() throws {
        let pipe = Pipe()
        let input = pipe.fileHandleForWriting
        try input.close()
        let voice = LocalVoice(input: input)
        var failures = 0
        voice.onError = { _ in failures += 1; voice.cancel() }
        voice.cancel()
        precondition(failures == 1, "A failed cancellation must not reenter the error callback")
        voice.cancel()
        precondition(failures == 1)
        voice.stop()
        print("A failed speech pipe reports once and stops safely.")
    }
}
