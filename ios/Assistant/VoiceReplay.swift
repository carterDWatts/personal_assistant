#if DEBUG
import AVFoundation

// The test target feeds prerecorded buffers through the production recognizer.
// This path never obtains an input node or requests microphone permission.
extension LiveVoice {
    func replay(_ url: URL) async throws {
        try await beginReplay()
        try await feedRecording(url)
    }

    func feedRecording(_ url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.processingFormat.sampleRate * 0.02)
        let clock = ContinuousClock()
        var deadline = clock.now
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            try file.read(into: buffer)
            feedReplay(buffer)
            deadline += .milliseconds(20)
            try await clock.sleep(until: deadline)
        }
        // Use actual silence and the production endpoint timer, not endAudio().
        for _ in 0..<150 {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(file.processingFormat.channelCount) {
                if let samples = buffer.floatChannelData?[channel] { samples.initialize(repeating: 0, count: Int(frames)) }
            }
            feedReplay(buffer)
            deadline += .milliseconds(20)
            try await clock.sleep(until: deadline)
        }
    }
}
#endif
