import AVFoundation

@main struct MeetingMediaCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let silent = root.appendingPathComponent("silent.mp4")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32ARGB, nil, &pixel)
        let frame = pixel!
        CVPixelBufferLockBaseAddress(frame, [])
        let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<CVPixelBufferGetDataSize(frame) { bytes[i] = UInt8.random(in: 0...255) }
        CVPixelBufferUnlockBaseAddress(frame, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        precondition(pixels.append(frame, withPresentationTime: .zero))
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        precondition(pixels.append(frame, withPresentationTime: CMTime(seconds: 1.9, preferredTimescale: 600)))
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished(); await writer.finishWriting()
        precondition(writer.status == .completed)
        let wav = root.appendingPathComponent("speech.wav")
        try tone(wav)
        let composition = AVMutableComposition()
        let sources = [(AVURLAsset(url: silent), AVMediaType.video), (AVURLAsset(url: wav), AVMediaType.audio)]
        for (source, type) in sources {
            let tracks = try await source.loadTracks(withMediaType: type)
            try composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: tracks[0], at: .zero)
        }
        let video = root.appendingPathComponent("meeting.mp4")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        export.outputURL = video; export.outputFileType = .mp4
        await export.export()
        precondition(export.status == .completed)
        let original = try Data(contentsOf: video)
        let audio = root.appendingPathComponent("audio.m4a")
        try await MeetingMedia.extractAudio(from: video, to: audio)
        let asset = AVURLAsset(url: audio)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        precondition(videos.isEmpty && audios.count == 1)
        let duration = try await asset.load(.duration).seconds
        precondition(abs(duration - 2) < 0.1)
        let file = try AVAudioFile(forReading: audio)
        precondition(file.length > 0)
        let unchanged = try Data(contentsOf: video)
        precondition(unchanged == original)
        let size = try Data(contentsOf: audio).count
        precondition(size < original.count)
        for source in [silent, root.appendingPathComponent("missing.mp4")] {
            let output = root.appendingPathComponent(UUID().uuidString + ".m4a")
            do { try await MeetingMedia.extractAudio(from: source, to: output); fatalError("Invalid input accepted") }
            catch { precondition(!FileManager.default.fileExists(atPath: output.path)) }
        }
        let cancelled = root.appendingPathComponent("cancelled.m4a")
        let task = Task { try await MeetingMedia.extractAudio(from: video, to: cancelled) }
        task.cancel()
        do { try await task.value; fatalError("Cancelled import completed") } catch {}
        precondition(!FileManager.default.fileExists(atPath: cancelled.path))
        do { try await MeetingMedia.extractAudio(from: video, to: audio); fatalError("Existing file accepted") } catch {}
        let kept = try Data(contentsOf: audio).count
        precondition(kept == size)
        print("MP4 audio extracted: \(original.count) → \(size) bytes. Video preserved; invalid and cancelled imports leave no output.")
    }
    static func tone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        for i in 0..<32000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 16000) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        try file.write(from: buffer)
    }
}
