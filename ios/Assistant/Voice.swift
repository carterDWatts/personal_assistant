import AVFoundation
import Speech
import os

/// Feeds microphone buffers to the recognizer from the audio thread and reports a level now and then.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var count = 0
    var onLevel: ((Double) -> Void)?
    var onSample: ((Int, Double, String) -> Void)?

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); self.request = request; lock.unlock()
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = request; lock.unlock()
        request?.append(buffer)
        count += 1
        guard count % 3 == 0, let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = Double(sqrt(sum / Float(n)))
        onLevel?(min(1, rms * 8))
        if count == 3 || count % 600 == 0 { onSample?(count, rms, buffer.format.description) }
    }
}

/// A continuous voice conversation. Recognition runs on the microphone; replies are synthesized
/// and played through the same audio engine, so the phone's voice processing removes them from
/// what the microphone hears and the user can talk over a reply.
@MainActor final class LiveVoice: ObservableObject {
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var active = false
    @Published private(set) var speaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var muted = false
    var onSpeech: (() -> Void)?
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?

    /// Silence that ends an utterance. Long enough to think mid-sentence, short enough to feel answered.
    static let pause: TimeInterval = 1.1

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let capture = Capture()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var listening = UUID()
    private var heardAt = Date()
    private var endpoint: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    private var onDevice = UserDefaults.standard.bool(forKey: "onDeviceRecognition")
    private var queue: [String] = []
    private var rendering = false
    private var hosted: [(URL, String)] = []
    private var fetching = false
    private var playbackFormat: AVAudioFormat?
    private var playing = 0
    private var playback = UUID()
    private var echo = PlaybackEcho()
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "assistant", category: "voice")

    init() {
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in if self?.muted == false { self?.inputLevel = level } }
        }
        capture.onSample = { [weak self] count, rms, format in
            Task { @MainActor [weak self] in self?.log.notice("microphone buffer \(count) rms \(rms, privacy: .public) \(format, privacy: .public)") }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.active,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
                self.stop()
                self.onError?("Voice stopped for another sound.")
            }
        })
    }

    func start() {
        guard !active else { return }
        Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard let self else { return }
            guard microphone else { self.onError?("Allow the microphone in Settings to talk."); return }
            guard speech == .authorized else { self.onError?("Allow speech recognition in Settings to talk."); return }
            self.begin()
        }
    }

    private func begin() {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        let input = engine.inputNode
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
            // The voice-processing unit gives echo cancellation, so speech playback goes through this engine too.
            try input.setVoiceProcessingEnabled(true)
        } catch {
            failed("Voice couldn’t start: \(error.localizedDescription)"); return
        }
        if player.engine == nil { engine.attach(player) }
        let format = playbackFormat ?? AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        playbackFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let capture = capture
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { buffer, _ in
            capture.consume(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); failed("The microphone couldn’t start: \(error.localizedDescription)"); return }
        active = true
        let route = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        log.notice("voice started, input \(route, privacy: .public), format \(input.outputFormat(forBus: 0).description, privacy: .public), on-device \(self.onDevice)")
        listen()
        refresh = Task { [weak self] in
            // The recognizer stops after about a minute of audio; start a fresh request between utterances.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, self.active, self.transcript.isEmpty else { continue }
                self.listen()
            }
        }
    }

    private func failed(_ text: String) {
        log.error("voice failed: \(text, privacy: .public)")
        stop()
        onError?(text)
    }

    private func listen() {
        task?.cancel(); task = nil
        guard let recognizer, recognizer.isAvailable else { failed("Speech recognition isn’t available right now."); return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = onDevice && recognizer.supportsOnDeviceRecognition
        self.request = request
        capture.attach(request)
        let token = UUID()
        listening = token
        transcript = ""
        heardAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in self?.recognized(token, result, error) }
        }
        log.notice("listening, on-device \(request.requiresOnDeviceRecognition), available \(recognizer.isAvailable), supports on-device \(recognizer.supportsOnDeviceRecognition)")
    }

    private func recognized(_ token: UUID, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard active, listening == token else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                if echo.matches(text) {
                    log.info("ignored playback echo")
                    if result.isFinal { listen() }
                    return
                }
                let first = transcript.isEmpty
                if text != transcript { transcript = text; heardAt = Date() }
                if first { log.notice("heard speech"); onSpeech?() }
                if result.isFinal { finish() } else { armEndpoint() }
                return
            }
            if result.isFinal { listen(); return }
        }
        if let error {
            let failure = error as NSError
            log.error("recognition ended: \(failure.domain, privacy: .public) \(failure.code) \(failure.localizedDescription, privacy: .public)")
            if !transcript.isEmpty { finish(); return }
            if !onDevice, recognizer?.supportsOnDeviceRecognition == true { onDevice = true }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.active, self.listening == token else { return }
                self.listen()
            }
        }
    }

    private func armEndpoint() {
        endpoint?.cancel()
        endpoint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled, let self, self.active else { return }
            if Date().timeIntervalSince(self.heardAt) >= Self.pause - 0.05 { self.finish() }
        }
    }

    private func finish() {
        endpoint?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        request?.endAudio()
        listen()
        if !text.isEmpty { onUtterance?(text) }
    }

    /// Muting drops the microphone from the recognizer; playback continues and the level meter rests.
    func setMuted(_ value: Bool) {
        guard active, value != muted else { return }
        muted = value
        if value {
            endpoint?.cancel()
            listening = UUID(); task?.cancel(); task = nil
            request?.endAudio(); request = nil
            capture.attach(nil)
            transcript = ""; inputLevel = 0
        } else {
            listen()
        }
    }

    func speak(_ text: String) {
        guard active else { return }
        queue.append(text)
        render()
    }

    /// Speech synthesized on the host: fetched in order, decoded, and scheduled on the same player as local speech.
    func play(_ url: URL, text: String) {
        guard active else { return }
        hosted.append((url, text))
        fetch()
    }

    private func fetch() {
        guard !fetching, !hosted.isEmpty else { return }
        let (url, text) = hosted.removeFirst()
        fetching = true
        let generation = playback
        echo.record(text); echo.resumed(); speaking = true
        Task { [weak self] in
            var buffer: AVAudioPCMBuffer?
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension))
                try data.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let audio = try AVAudioFile(forReading: file)
                if let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) {
                    try audio.read(into: pcm)
                    buffer = pcm
                }
            } catch {
                self?.log.error("host speech failed: \(error.localizedDescription, privacy: .public)")
            }
            guard let self else { return }
            self.fetching = false
            guard generation == self.playback else { return }
            if let buffer { self.received(buffer, generation) }
            if self.hosted.isEmpty && self.playing == 0 && !self.rendering && buffer == nil { self.speaking = false; self.echo.finished() }
            self.fetch()
        }
    }

    private func render() {
        guard !rendering, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        rendering = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = LiveVoice.voice
        let generation = playback
        echo.record(text); echo.resumed(); speaking = true
        synthesizer.write(utterance) { [weak self] buffer in
            Task { @MainActor [weak self] in self?.received(buffer, generation) }
        }
    }

    private func received(_ buffer: AVAudioBuffer, _ generation: UUID) {
        guard generation == playback else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            rendering = false
            if queue.isEmpty && playing == 0 { speaking = false; echo.finished() }
            render()
            return
        }
        if playbackFormat != pcm.format {
            playbackFormat = pcm.format
            engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
        }
        playing += 1
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.played(generation) }
        }
        if !player.isPlaying { player.play() }
    }

    private func played(_ generation: UUID) {
        guard generation == playback else { return }
        playing -= 1
        if playing == 0 && !rendering && queue.isEmpty && !fetching && hosted.isEmpty { speaking = false; echo.finished() }
    }

    func silencePlayback() {
        playback = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        queue.removeAll(); rendering = false; playing = 0
        hosted.removeAll(); fetching = false
        if player.engine != nil { player.stop() }
        if speaking { speaking = false; echo.finished() }
    }

    func stop() {
        guard active else { return }
        active = false
        silencePlayback()
        endpoint?.cancel(); refresh?.cancel()
        listening = UUID()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        capture.attach(nil)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = ""; inputLevel = 0; muted = false
    }

    // The best installed English voice unless one was chosen in Settings. Premium voices are downloads in
    // Settings › Accessibility › Spoken Content › Voices; they sound far better than the built-in ones.
    static var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "voice"), let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return candidates.first
    }

    static var candidates: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { rank($0) > rank($1) }
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        (voice.quality == .premium ? 30 : voice.quality == .enhanced ? 20 : 0) + (voice.language == "en-US" ? 5 : 0)
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Compact"
        }
    }
}
