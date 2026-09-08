import AVFoundation

@MainActor
final class LocalVoice {
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: Task<Void,Never>?
    private var watchdog: Task<Void,Never>?
    private var buffer = Data()
    private var generation = UUID()
    private var streams: [String: AsyncStream<AVAudioPCMBuffer>.Continuation] = [:]

    init(input: FileHandle? = nil) { self.input = input }

    private func fail(_ text: String) {
        stop() // Detach the failed pipe before callbacks can cancel playback.
        onError?(text)
    }

    func start() {
        stop()
        guard let settings = Bundle.main.infoDictionary,
              let root = settings["AssistantRoot"] as? String,
              let python = settings["AssistantVoicePython"] as? String else { onError?("Rebuild the app to configure voice."); return }
        let token = generation
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-m", "engine.voice.synthesize"]
        child.currentDirectoryURL = URL(fileURLWithPath: root)
        child.environment = ProcessInfo.processInfo.environment.filter { ["HOME","PATH","LANG","TMPDIR"].contains($0.key) }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        let events = outputStream(from: stdout.fileHandleForReading)
        output = Task { @MainActor [weak self] in
            for await data in events {
                guard let self, self.generation == token else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String:Any] else { continue }
                    let id = event["id"] as? String ?? ""
                    switch event["type"] as? String {
                    case "ready": self.watchdog?.cancel(); self.onReady?()
                    case "done": self.streams.removeValue(forKey: id)?.finish()
                    case "audio":
                        guard let continuation = self.streams[id], let encoded = event["pcm"] as? String,
                              let bytes = Data(base64Encoded: encoded), bytes.count % 4 == 0,
                              let rate = event["rate"] as? Double, rate > 0,
                              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bytes.count/4)) else { continue }
                        pcm.frameLength = pcm.frameCapacity
                        bytes.withUnsafeBytes { raw in
                            if let address = raw.baseAddress { memcpy(pcm.floatChannelData![0],address,bytes.count) }
                        }
                        continuation.yield(pcm)
                    case "error": self.fail(event["text"] as? String ?? "Local voice failed."); return
                    default: break
                    }
                }
            }
            guard let self, self.generation == token else { return }
            self.fail("Local voice stopped. Start voice to retry.")
        }
        do {
            try child.run(); process = child
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.fail("Local voice did not start. Rebuild the app to check its model.")
            }
        } catch { fail("Could not start local voice.") }
    }

    private func send(_ event: [String:Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { fail("Could not send text to local voice.") }
    }

    func render(_ text: String) -> AsyncStream<AVAudioPCMBuffer> {
        let id = UUID().uuidString
        return AsyncStream { continuation in
            streams[id] = continuation
            send(["type":"speak", "id":id, "text":text])
        }
    }

    func cancel() {
        streams.values.forEach { $0.finish() }; streams.removeAll()
        send(["type":"cancel"])
    }

    func stop() {
        generation = UUID(); watchdog?.cancel(); output?.cancel(); output = nil
        streams.values.forEach { $0.finish() }; streams.removeAll()
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; buffer = Data()
    }
}
