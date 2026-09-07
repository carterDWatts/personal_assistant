import AVFoundation

// Audio writes stay off the render and UI threads. Overflow fails instead of building stale audio.
final class SpeechInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "assistant.speech.input")
    private let lock = NSLock()
    private let handle: FileHandle
    private var stopped = false
    private var pending = 0
    private var level: Float = 0
    private var frames: UInt64 = 0
    var onFailure: (@Sendable () -> Void)?
    init(_ handle: FileHandle) { self.handle = handle }
    func stats() -> (Float,UInt64) { lock.lock(); defer { lock.unlock() }; return (level,frames) }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var energy: Float = 0
        for i in 0..<count { energy += samples[i]*samples[i] }
        var rate = UInt32(buffer.format.sampleRate).littleEndian
        var size = buffer.frameLength.littleEndian
        var data = Data(bytes: &rate, count: 4)
        data.append(Data(bytes: &size, count: 4)); data.append(Data(bytes: samples,count: count*4))
        lock.lock()
        if stopped { lock.unlock(); return }
        level = sqrt(energy/Float(count)); frames += UInt64(count)
        if pending + data.count > 384000 {
            stopped = true; lock.unlock(); onFailure?(); return
        }
        pending += data.count; lock.unlock()
        queue.async { [self] in
            lock.lock(); let write = !stopped; lock.unlock()
            if write {
                do { try handle.write(contentsOf: data) }
                catch { stop(); onFailure?() }
            }
            lock.lock(); pending -= data.count; lock.unlock()
        }
    }
}

@MainActor
final class LocalSpeech {
    var onReady: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var input: SpeechInput?
    private var process: Process?
    private var output: Task<Void,Never>?
    private var watchdog: Task<Void,Never>?
    private var buffer = Data()
    private var generation = UUID()

    func start() {
        stop()
        guard let settings = Bundle.main.infoDictionary,
              let root = settings["AssistantRoot"] as? String,
              let python = settings["AssistantPython"] as? String else { onError?("Rebuild the app to configure local speech."); return }
        let token = generation
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-m", "engine.voice.recognize"]
        child.currentDirectoryURL = URL(fileURLWithPath: root)
        child.environment = ProcessInfo.processInfo.environment.filter { ["HOME","PATH","LANG","TMPDIR","ASSISTANT_SPEECH_MODEL"].contains($0.key) }
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        let stream = outputStream(from: stdout.fileHandleForReading)
        let writer = SpeechInput(stdin.fileHandleForWriting)
        writer.onFailure = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.onError?("Speech processing fell behind. Start voice again.")
            }
        }
        input = writer
        output = Task { @MainActor [weak self] in
            for await data in stream {
                guard let self, self.generation == token else { return }
                self.buffer.append(data)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer[..<end]; self.buffer.removeSubrange(...end)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String:Any] else { continue }
                    let text = event["text"] as? String ?? ""
                    switch event["type"] as? String {
                    case "ready": self.watchdog?.cancel(); self.onReady?()
                    case "partial": self.onPartial?(text)
                    case "final": self.onFinal?(text)
                    case "error": self.onError?(text)
                    default: break
                    }
                }
            }
            guard let self, self.generation == token else { return }
            self.onError?("Local speech stopped. Start voice to retry.")
        }
        do {
            try child.run(); process = child
            watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.onError?("Local speech did not start. Check the speech model installation.")
            }
        } catch { onError?("Could not start local speech.") }
    }

    func stop() {
        generation = UUID(); watchdog?.cancel(); output?.cancel(); output = nil
        input?.stop(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; buffer = Data()
    }
}
