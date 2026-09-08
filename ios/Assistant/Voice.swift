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
    @Published private(set) var ready = false
    @Published private(set) var speaking = false
    @Published private(set) var transcript = ""
    @Published private(set) var muted = false
    var onSpeech: (() -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onUtterance: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let cuePlayer = AVAudioPlayerNode()
    private var mode: VoiceCue?
    private var replyAudioComplete = true
    private let synthesizer = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let capture = Capture()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var listening = UUID()
    private var heardAt = Date()
    private var signalAt = Date.distantPast
    private var endpoint: Task<Void, Never>?
    private var draft = DictationDraft()
    private var refresh: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastBuffer = Date.distantPast
    private var captureRestarts = 0
    private var usesMicrophone = false
    private var onDevice = true
    private var recognitionFailures = 0
    private var startToken = UUID()
    private var download: Task<Void, Never>?
    private var playbackText = ""
    private var queue: [String] = []
    private var rendering = false
    private var hosted: [(URL, String)] = []
    private var fetching = false
    private var playbackFormat: AVAudioFormat?
    private var playing = 0
    private var playback = UUID()
    private var echo = PlaybackEcho()
    private var interruption = PlaybackInterruption()
    private var interruptionCheck: Task<Void, Never>?
    private var heardEcho = false
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "assistant", category: "voice")

    init() {
        capture.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                self.lastBuffer = Date()
                if !self.ready {
                    self.ready = true
                    VoiceDiagnostics.record("capture_ready")
                    self.setMode(.listening)
                }
                guard !self.muted else { return }
                self.inputLevel = level
                if level > 0.04 && !self.speaking { self.signalAt = Date() }
            }
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
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Route negotiation can stop the engine just after a successful start.
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.active, self.usesMicrophone, !self.engine.isRunning else { return }
                self.recoverCapture()
            }
        })
    }

    func start() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ASSISTANT_VOICE_TEST"] != "1" else { return }
        #endif
        guard !active else { return }
        VoiceDiagnostics.record("talk_pressed")
        let token = UUID(); startToken = token
        Task { [weak self] in
            let microphone = await AVAudioApplication.requestRecordPermission()
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard let self, self.startToken == token else { return }
            guard microphone else { self.onError?("Allow the microphone in Settings to talk."); return }
            guard speech == .authorized else { self.onError?("Allow speech recognition in Settings to talk."); return }
            self.onDevice = UserDefaults.standard.object(forKey: "onDeviceRecognition") as? Bool ?? true
            self.recognitionFailures = 0
            self.captureRestarts = 0
            self.begin()
        }
    }

    private func begin() {
        guard !active else { return }
        let session = AVAudioSession.sharedInstance()
        usesMicrophone = true
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            // Creating the I/O node before activation can bind it to the previous route.
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            failed("Voice couldn’t start: \(error.localizedDescription)"); return
        }
        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).sampleRate > 0, input.outputFormat(forBus: 0).channelCount > 0 else {
            failed("The microphone has no active audio route."); return
        }
        if player.engine == nil { engine.attach(player) }
        let format = playbackFormat ?? AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        playbackFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if cuePlayer.engine == nil { engine.attach(cuePlayer) }
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
        let capture = capture
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { buffer, _ in
            capture.consume(buffer)
        }
        // Attach recognition before any microphone buffers arrive.
        active = true
        ready = false
        listen()
        guard active else { return }
        engine.prepare()
        do { try engine.start() } catch { failed("The microphone couldn’t start: \(error.localizedDescription)"); return }
        VoiceDiagnostics.record("engine_started")
        lastBuffer = Date()
        watchCapture()
        let route = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        log.notice("voice started, input \(route, privacy: .public), format \(input.outputFormat(forBus: 0).description, privacy: .public), on-device \(self.onDevice)")
        refresh = Task { [weak self] in
            // The recognizer stops after about a minute of audio; start a fresh request between utterances.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard let self, self.active, !self.muted, self.transcript.isEmpty else { continue }
                self.listen()
            }
        }
    }

    #if DEBUG
    var lastInputSound: Date { signalAt }
    private(set) var playedBufferCount = 0

    func beginReplay() async throws {
        stop()
        let permission = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard permission == .authorized else { throw NSError(domain: "VoiceReplay", code: 1) }
        usesMicrophone = false
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        if player.engine == nil { engine.attach(player) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        playbackFormat = format
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if cuePlayer.engine == nil { engine.attach(cuePlayer) }
        engine.connect(cuePlayer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        active = true
        onDevice = true
        listen()
    }

    func feedReplay(_ buffer: AVAudioPCMBuffer) { capture.consume(buffer) }
    func endReplaySegment() { request?.endAudio() }
    #endif

    private func watchCapture() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.active else { return }
                guard !self.muted, Date().timeIntervalSince(self.lastBuffer) > 2 else { continue }
                self.recoverCapture()
                return
            }
        }
    }

    private func recoverCapture() {
        guard active else { return }
        guard captureRestarts < 2 else {
            failed("The microphone stopped delivering audio."); return
        }
        captureRestarts += 1
        VoiceDiagnostics.record("capture_restarted")
        log.notice("restarting stalled microphone")
        stop()
        begin()
    }

    private func failed(_ text: String) {
        VoiceDiagnostics.record("capture_failed")
        log.error("voice failed: \(text, privacy: .public)")
        stop()
        onError?(text)
    }

    private func listen(preservingUtterance: Bool = false) {
        guard active, !muted else { return }
        draft.restart(preserving: preservingUtterance)
        interruptionCheck?.cancel(); interruptionCheck = nil
        listening = UUID()
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
        transcript = draft.text
        interruption = PlaybackInterruption()
        heardEcho = false
        if !preservingUtterance { heardAt = Date() }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in self?.recognized(token, result, error) }
        }
        log.notice("listening, on-device \(request.requiresOnDeviceRecognition), available \(recognizer.isAvailable), supports on-device \(recognizer.supportsOnDeviceRecognition)")
    }

    private func recognized(_ token: UUID, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        guard active, !muted, listening == token else { return }
        interruptionCheck?.cancel(); interruptionCheck = nil
        if let result {
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                if transcript.isEmpty && echo.suppressDuringPlayback(text, final: result.isFinal) {
                    heardEcho = true
                    interruption = PlaybackInterruption()
                    log.notice("ignored playback echo")
                    if result.isFinal { listen() }
                    return
                }
                heardEcho = false
                if transcript.isEmpty && !interruption.accept(text, guarded: echo.isRecent(), final: result.isFinal) {
                    if result.isFinal { listen() }
                    else if text.split(separator: " ").count >= 3 {
                        // Do not wait for another ASR callback to confirm a stable
                        // non-echo phrase; it may arrive hundreds of ms later.
                        interruptionCheck = Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(160))
                            guard !Task.isCancelled else { return }
                            self?.recognized(token, result, nil)
                        }
                    }
                    return
                }
                recognitionFailures = 0
                let first = transcript.isEmpty
                draft.update(text)
                let combined = draft.text
                if combined != transcript { transcript = combined; heardAt = Date() }
                if first { signalAt = Date(); VoiceDiagnostics.record("speech_accepted"); log.notice("heard speech"); onSpeech?() }
                // A recognizer segment ending is not the user yielding the floor.
                if result.isFinal { listen(preservingUtterance: true) }
                armEndpoint()
                return
            }
            if result.isFinal {
                listen(preservingUtterance: !transcript.isEmpty)
                if !transcript.isEmpty { armEndpoint() }
                return
            }
        }
        if let error {
            let failure = error as NSError
            VoiceDiagnostics.record("recognition_error", ["code": Double(failure.code)])
            log.error("recognition ended: \(failure.domain, privacy: .public) \(failure.code) \(failure.localizedDescription, privacy: .public)")
            recognitionFailures += 1
            guard recognitionFailures <= 4 else {
                failed("Speech recognition stopped. Tap Talk to reconnect."); return
            }
            if recognitionFailures == 2 { onDevice.toggle() }
            let delay = min(2.0, Double(recognitionFailures) * 0.4)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.active, self.listening == token else { return }
                self.listen(preservingUtterance: !self.transcript.isEmpty)
                if !self.transcript.isEmpty { self.armEndpoint() }
            }
        }
    }

    private func armEndpoint() {
        endpoint?.cancel()
        endpoint = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.active else { return }
                let sinceWords = Date().timeIntervalSince(self.heardAt)
                let sinceSound = Date().timeIntervalSince(self.signalAt)
                // Punctuation is an ASR guess. A thinking pause must not surrender
                // the turn, and stalled text must never override ongoing speech.
                if min(sinceWords, sinceSound) >= voicePause(self.transcript) {
                    self.commitUtterance(); return
                }
            }
        }
    }

    private func commitUtterance() {
        endpoint?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { VoiceDiagnostics.record("utterance_submitted", ["since_sound": Date().timeIntervalSince(signalAt), "since_words": Date().timeIntervalSince(heardAt)]) }
        request?.endAudio()
        listen()
        if !text.isEmpty { log.notice("utterance submitted"); onUtterance?(text) }
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
        VoiceDiagnostics.record("audio_received")
        hosted.append((url, text))
        fetch()
    }

    private func fetch() {
        guard !fetching, playing < 2, !hosted.isEmpty else { return }
        let (url, text) = hosted.removeFirst()
        fetching = true
        let generation = playback
        playbackText = text
        download = Task { [weak self] in
            let started = Date()
            var buffer: AVAudioPCMBuffer?
            do {
                let data: Data
                let prefix = url.absoluteString.hasPrefix("data:audio/wav;base64,") ? "data:audio/wav;base64," : "data:audio/mp4;base64,"
                #if DEBUG
                let replayFile = url.isFileURL && ProcessInfo.processInfo.environment["ASSISTANT_VOICE_TEST"] == "1"
                #else
                let replayFile = false
                #endif
                if replayFile {
                    data = try Data(contentsOf: url)
                } else if url.absoluteString.hasPrefix(prefix) {
                    let encoded = String(url.absoluteString.dropFirst(prefix.count))
                    guard encoded.count <= 86_000, let decoded = Data(base64Encoded: encoded) else { throw URLError(.cannotDecodeContentData) }
                    data = decoded
                } else {
                    let (downloaded, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
                    data = downloaded
                }
                guard data.count <= 5_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                let suffix = prefix.contains("/wav;") ? "wav" : (url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
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
            guard generation == self.playback, !Task.isCancelled else { return }
            self.fetching = false
            if let buffer {
                self.received(buffer, generation)
                #if DEBUG
                print("Phone audio preparation:", Date().timeIntervalSince(started))
                #endif
            }
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
        playbackText = text
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
        guard let format = playbackFormat, let converted = convert(pcm, to: format) else { return }
        setMode(.speaking)
        echo.record(playbackText); speaking = true
        playing += 1
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.played(generation) }
        }
        if !player.isPlaying { player.play(); VoiceDiagnostics.record("playback_started"); onPlaybackStarted?() }
    }

    private func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    private func played(_ generation: UUID) {
        guard generation == playback else { return }
        playing -= 1
        #if DEBUG
        playedBufferCount += 1
        #endif
        fetch()
        if playing == 0 && !rendering && queue.isEmpty && !fetching && hosted.isEmpty {
            speaking = false; echo.finished()
            if replyAudioComplete { setMode(.listening) }
            if heardEcho && transcript.isEmpty { listen() }
        }
    }

    func prepareReply() {
        guard active else { return }
        replyAudioComplete = false
        setMode(.thinking)
    }

    func finishReplyAudio() {
        replyAudioComplete = true
        if !speaking && !fetching && !rendering && hosted.isEmpty && queue.isEmpty { setMode(.listening) }
    }

    func userBeganSpeaking() {
        // Acknowledge an interruption visually; never chime over the user's words.
        mode = .listening
    }

    private func setMode(_ next: VoiceCue) {
        guard active, !muted, mode != next else { return }
        mode = next
        guard engine.isRunning, let format = playbackFormat,
              let buffer = next.buffer(sampleRate: format.sampleRate) else { return }
        cuePlayer.stop()
        cuePlayer.scheduleBuffer(buffer)
        cuePlayer.play()
        // This node shares the voice-processing engine's echo reference. It never
        // pauses recognition, queues behind speech, or fires speech-start callbacks.
    }

    func silencePlayback() {
        download?.cancel(); download = nil
        playback = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        queue.removeAll(); rendering = false; playing = 0
        hosted.removeAll(); fetching = false
        if player.engine != nil { player.stop() }
        if cuePlayer.engine != nil { cuePlayer.stop() }
        if speaking { speaking = false; echo.finished();  }
    }

    func stop() {
        startToken = UUID()
        let wasActive = active
        active = false
        ready = false
        mode = nil
        replyAudioComplete = true
        silencePlayback()
        endpoint?.cancel(); refresh?.cancel(); watchdog?.cancel(); interruptionCheck?.cancel()
        listening = UUID()
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        capture.attach(nil)
        if wasActive && usesMicrophone { engine.inputNode.removeTap(onBus: 0) }
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


/// Bounded development diagnostics. No recordings, transcripts, tokens, or account data.
@MainActor enum VoiceDiagnostics {
    #if DEBUG
    private static var entries: [[String: Any]] = []
    #endif
    static func record(_ event: String, _ values: [String: Double] = [:]) {
        #if DEBUG
        entries.append(["event": event, "time": Date().timeIntervalSince1970, "values": values])
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
        guard let data = try? JSONSerialization.data(withJSONObject: entries),
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("voice-diagnostics.json"), options: .atomic)
        #endif
    }
}


/// Quiet, rounded tones: an upward listening cue, a downward handoff, and a soft reply cue.
enum VoiceCue: CaseIterable {
    case listening, thinking, speaking

    func buffer(sampleRate: Double = 24000) -> AVAudioPCMBuffer? {
        let duration = self == .speaking ? 0.045 : 0.09
        let count = Int(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let samples = pcm.floatChannelData?[0] else { return nil }
        pcm.frameLength = AVAudioFrameCount(count)
        let pitches: (Double, Double) = switch self {
        case .listening: (554, 740)
        case .thinking: (440, 330)
        case .speaking: (466, 466)
        }
        let volume = self == .speaking ? 0.025 : 0.045
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(count - 1)
            let envelope = pow(sin(.pi * progress), 2)
            let phase = 2 * Double.pi * (pitches.0 * t + (pitches.1 - pitches.0) * t * t / (2 * duration))
            samples[i] = Float(volume * envelope * (sin(phase) + 0.15 * sin(2 * phase)))
        }
        return pcm
    }
}
