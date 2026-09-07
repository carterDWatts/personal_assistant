import AVFoundation
import OSLog

@MainActor
final class LiveVoice: ObservableObject {
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var active = false
    @Published private(set) var speaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var startupMessage = "Starting voice"
    var onSpeech: (() -> Void)?
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synth = LocalVoice()
    private var starting = false
    private var captureRequested = false
    private var prepared = false
    var isPrepared: Bool { recognitionReady && voiceReady }
    private var recognitionReady = false
    private var voiceReady = false
    private let speech = LocalSpeech()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var meter: Task<Void, Never>?
    private var playbackTasks: [UUID: Task<Void, Never>] = [:]
    private var playback = UUID()
    private var permission = UUID()
    private var speechQueue: [String] = []
    private var scheduled = 0
    private var rendering = 0
    private var tapInstalled = false
    private var recovery: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var lastRecovery = Date.distantPast
    private let log = Logger(subsystem: "com.carterwatts.personal-assistant", category: "voice")
    private var configurationObserver: NSObjectProtocol?

    init() {
        speech.onReady = { [weak self] in
            guard let self else { return }; self.recognitionReady = true
            if self.isPrepared { self.begin() }
        }
        synth.onReady = { [weak self] in
            guard let self else { return }; self.voiceReady = true
            if self.isPrepared { self.begin() }
        }
        synth.onError = { [weak self] text in self?.failed(text) }
        speech.onPartial = { [weak self] text in
            guard let self, self.active else { return }
            let first = self.transcript.isEmpty
            self.transcript = text
            if first { self.onSpeech?() }
        }
        speech.onFinal = { [weak self] text in
            guard let self, self.active else { return }
            self.transcript = ""
            self.onUtterance?(text)
        }
        speech.onError = { [weak self] text in self?.failed(text) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.active, !self.engine.isRunning else { return }
                self.recoverAudio()
            }
        }
    }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        speech.start(); synth.start()
    }

    private func failed(_ text: String) {
        let requested = starting || captureRequested || active
        stop()
        speech.stop(); synth.stop()
        prepared = false; recognitionReady = false; voiceReady = false
        if requested { onError?(text) }
    }

    func start() {
        starting = true
        let token = UUID(); permission = token
        prepare()
        startupMessage = "Allow microphone access if macOS asks"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            Task { @MainActor [weak self] in
                guard let self, self.permission == token else { return }
                guard allowed else { self.starting = false; self.onError?("Allow Microphone in System Settings."); return }
                self.captureRequested = true
                self.startupMessage = self.isPrepared ? "Starting microphone" : "Preparing voice"
                if self.isPrepared { self.begin() }
            }
        }
    }

    private func begin() {
        guard captureRequested, isPrepared, !active else { return }
        let node = engine.inputNode
        do {
            // Speech playback goes through this engine too, providing the echo reference.
            if !node.isVoiceProcessingEnabled { try node.setVoiceProcessingEnabled(true) }
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            let format = node.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { stop(); onError?("No microphone found."); return }
            guard let feed = speech.input else { stop(); onError?("Local speech is not ready."); return }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
            tapInstalled = true
            do { try engine.start() } catch { node.removeTap(onBus: 0); tapInstalled = false; throw error }
            starting = false; active = true
            log.info("Audio capture started")
            meter?.cancel()
            meter = Task { @MainActor [weak self] in
                var reported = false
                while !Task.isCancelled {
                    guard let self, self.active else { return }
                    let (level, frames) = self.speech.input?.stats() ?? (0,0)
                    self.inputLevel = min(1, Double(level) * 12)
                    if frames > 0, !reported { self.log.info("Microphone buffers received"); reported = true }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }

        } catch { stop(); onError?("Could not start echo-cancelled voice. Check your audio devices and try again.") }
    }

    private func recoverAudio() {
        recovery?.cancel()
        recovery = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self, self.active, !self.engine.isRunning else { return }
            if Date().timeIntervalSince(self.lastRecovery) > 10 { self.recoveryAttempts = 0 }
            self.lastRecovery = Date(); self.recoveryAttempts += 1
            guard self.recoveryAttempts <= 3 else {
                self.stop(); self.onError?("Audio keeps disconnecting. Check your selected microphone."); return
            }
            self.log.info("Reconnecting audio after configuration change")
            self.silencePlayback()
            self.engine.stop()
            if self.tapInstalled { self.engine.inputNode.removeTap(onBus: 0); self.tapInstalled = false }
            self.active = false
            self.begin()
        }
    }

    func silencePlayback() {
        playback = UUID()
        synth.cancel(); player.stop()
        playbackTasks.values.forEach { $0.cancel() }; playbackTasks.removeAll()
        speechQueue.removeAll(); scheduled = 0; rendering = 0; speaking = false
    }

    func stop() {
        meter?.cancel(); meter = nil; inputLevel = 0
        recovery?.cancel(); recovery = nil
        permission = UUID(); starting = false; captureRequested = false; active = false
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        silencePlayback(); transcript = ""
        if recognitionReady {
            recognitionReady = false
            speech.reset()
        }
    }

    func speak(_ text: String) {
        guard active, text.rangeOfCharacter(from: .alphanumerics) != nil else { return }
        speechQueue.append(text)
        renderNext()
    }

    private func renderNext() {
        guard active, rendering == 0, !speechQueue.isEmpty else { return }
        let token = playback, id = UUID()
        let text = speechQueue.removeFirst()
        rendering += 1; speaking = true
        let stream = synth.render(text)
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
