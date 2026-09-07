import AVFoundation
import Speech

private final class MicrophoneFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = value
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; request?.append(buffer)
    }
}

@MainActor
final class LiveVoice: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var speaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var startupMessage = "Starting voice"
    var onSpeech: (() -> Void)?
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer()
    private let feed = MicrophoneFeed()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Task<Void, Never>?
    private var rotation: Task<Void, Never>?
    private var playbackTasks: [UUID: Task<Void, Never>] = [:]
    private var capture = UUID()
    private var playback = UUID()
    private var permission = UUID()
    private var speechQueue: [String] = []
    private var scheduled = 0
    private var rendering = 0
    private var failures = 0
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.engine.isRunning else { return }
                self.stop()
                self.onError?("Audio device changed. Start voice again.")
            }
        }
    }

    func start() {
        let token = UUID(); permission = token
        startupMessage = "Allow speech and microphone access if macOS asks"
        SFSpeechRecognizer.requestAuthorization { [weak self] result in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                Task { @MainActor [weak self] in
                    guard let self, self.permission == token else { return }
                    guard result == .authorized, allowed else {
                        self.onError?("Allow Microphone and Speech Recognition in System Settings."); return
                    }
                    self.startupMessage = "Starting audio"
                    self.begin()
                }
            }
        }
    }

    private func begin() {
        guard !active else { return }
        guard recognizer?.isAvailable == true else { onError?("Speech recognition is unavailable."); return }
        let node = engine.inputNode
        do {
            // Speech playback goes through this engine too, providing the echo reference.
            try node.setVoiceProcessingEnabled(true)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { onError?("No microphone found."); return }
            let feed = self.feed
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
            tapInstalled = true
            do { try engine.start() } catch { node.removeTap(onBus: 0); tapInstalled = false; throw error }
            active = true; failures = 0
            beginRecognition()
        } catch { onError?("Could not start echo-cancelled voice. Check your audio devices and try again.") }
    }

    private func beginRecognition() {
        capture = UUID()
        recognition?.cancel(); request?.endAudio()
        silence?.cancel(); rotation?.cancel()
        transcript = ""
        guard active, let recognizer else { return }
        let token = capture
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req; feed.set(req)
        recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.active, self.capture == token else { return }
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, text != self.transcript {
                        let first = self.transcript.isEmpty
                        self.transcript = text; self.failures = 0
                        if first { self.onSpeech?() }
                        self.silence?.cancel()
                        self.silence = Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            guard !Task.isCancelled, let self, self.capture == token else { return }
                            self.finishUtterance()
                        }
                    }
                    if result.isFinal { self.finishUtterance() }
                } else if error != nil {
                    self.failures += 1
                    if self.failures >= 3 {
                        self.stop(); self.onError?("Speech recognition stopped. Start voice to retry.")
                    } else { self.finishUtterance() }
                }
            }
        }
        // Rotate Apple's finite recognition sessions without stopping the audio engine.
        rotation = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000_000)
            guard !Task.isCancelled, let self, self.capture == token else { return }
            self.finishUtterance()
        }
    }

    private func finishUtterance() {
        let text = transcript
        beginRecognition()
        if !text.isEmpty { onUtterance?(text) }
    }

    func silencePlayback() {
        playback = UUID()
        synth.stopSpeaking(at: .immediate); player.stop()
        playbackTasks.values.forEach { $0.cancel() }; playbackTasks.removeAll()
        speechQueue.removeAll(); scheduled = 0; rendering = 0; speaking = false
    }

    func stop() {
        permission = UUID(); active = false; capture = UUID()
        silence?.cancel(); rotation?.cancel(); feed.set(nil)
        recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        silencePlayback(); transcript = ""
    }

    func speak(_ text: String) {
        guard active, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speechQueue.append(text)
        renderNext()
    }

    private func renderNext() {
        guard active, rendering == 0, !speechQueue.isEmpty else { return }
        let token = playback, id = UUID()
        let utterance = AVSpeechUtterance(string: speechQueue.removeFirst())
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        rendering += 1; speaking = true
        // One consumer preserves buffer order, even when synthesis callbacks are rapid.
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { continuation.finish(); return }
                guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else { return }
                copy.frameLength = pcm.frameLength
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pcm.audioBufferList))
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for i in 0..<source.count {
                    if let from = source[i].mData, let to = target[i].mData { memcpy(to, from, Int(source[i].mDataByteSize)) }
                }
                continuation.yield(copy)
            }
        }
        playbackTasks[id] = Task { @MainActor [weak self] in
            var converter: AVAudioConverter?
            for await buffer in stream {
                guard let self, !Task.isCancelled, self.active, self.playback == token else { return }
                if converter == nil { converter = AVAudioConverter(from: buffer.format, to: self.playbackFormat) }
                guard let converter, let output = AVAudioPCMBuffer(pcmFormat: self.playbackFormat,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 48000 / buffer.format.sampleRate + 256)) else { continue }
                var supplied = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                guard error == nil, output.frameLength > 0 else { continue }
                self.scheduled += 1
                self.player.scheduleBuffer(output, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playback == token else { return }
                        self.scheduled -= 1
                        self.speaking = self.scheduled > 0 || self.rendering > 0
                    }
                }
                if !self.player.isPlaying { self.player.play() }
            }
            guard let self, self.playback == token else { return }
            self.rendering -= 1; self.speaking = self.scheduled > 0 || self.rendering > 0
            self.playbackTasks.removeValue(forKey: id)
            self.renderNext()
        }
    }
}
