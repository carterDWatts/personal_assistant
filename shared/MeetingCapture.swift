import AVFoundation
import Speech
import Combine

/// The render callback only copies audio; file I/O and speech ingestion run on a bounded queue.
private final class MeetingAudioSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "assistant.meeting.audio")
    private let lock = NSLock()
    private var pending = 0
    private var stopped = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private let file: AVAudioFile
    var onError: (@Sendable () -> Void)?
    init(file: AVAudioFile) { self.file = file }
    func attach(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        queue.async { self.request?.endAudio(); self.request = request }
    }
    func append(_ source: AVAudioPCMBuffer) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        buffer.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for i in input.indices { if let a = input[i].mData, let b = output[i].mData { memcpy(b, a, Int(input[i].mDataByteSize)) } }
        lock.lock()
        guard !stopped, pending < 100 else {
            let report = !stopped; stopped = true; lock.unlock()
            if report { onError?() }; return
        }
        pending += 1; lock.unlock()
        queue.async { [self] in
            do { try file.write(from: buffer); request?.append(buffer) }
            catch { lock.lock(); let report = !stopped; stopped = true; lock.unlock(); if report { onError?() } }
            lock.lock(); pending -= 1; lock.unlock()
        }
    }
    func finish() async {
        lock.lock(); stopped = true; lock.unlock()
        await withCheckedContinuation { continuation in
            queue.async { self.request?.endAudio(); self.request = nil; continuation.resume() }
        }
    }
}

@MainActor final class MeetingCapture: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var working = false
    @Published private(set) var status = ""
    @Published private(set) var error = ""
    private let library: MeetingLibrary
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var sink: MeetingAudioSink?
    private var tasks: [UUID: SFSpeechRecognitionTask] = [:]
    private var rotation: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private var generation = UUID()
    private var currentSegment: UUID?
    private var meetingID: UUID?
    private var failures = 0
    private var started = Date()
    private var interruption: NSObjectProtocol?
    var active: Bool { recording || working }
    init(library: MeetingLibrary) {
        self.library = library
        #if os(iOS)
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.error = "Recording was interrupted. The audio and transcript so far are saved."
                await self.stop()
            }
        }
        #endif
    }
    deinit { if let interruption { NotificationCenter.default.removeObserver(interruption) } }
    private func authorize() async throws {
        let result = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard result == .authorized else { throw MeetingFailure("Allow speech recognition in Settings to transcribe conversations.") }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw MeetingFailure("On-device English transcription is unavailable. Enable English dictation in Settings and try again.")
        }
    }
    func start(title: String, runtime: String) async {
        guard !active else { return }
        working = true; error = ""; status = "Preparing microphone…"
        do {
            try await authorize()
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw MeetingFailure("Allow microphone access in Settings to record a meeting.") }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let id = try library.create(title: title, runtime: runtime)
            meetingID = id; started = Date(); failures = 0; generation = UUID()
            let name = id.uuidString + ".caf"
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw MeetingFailure("The microphone is unavailable. Try recording again.") }
            let url = library.directory.appendingPathComponent(name)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            try library.audio(id, name: name)
            let writer = MeetingAudioSink(file: file); sink = writer
            writer.onError = { [weak self] in Task { @MainActor in
                self?.error = "Recording couldn’t keep up or save audio. The transcript so far is preserved."
                await self?.stop()
            } }
            recording = true
            listen()
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in writer.append(buffer) }
            engine.prepare(); try engine.start()
            working = false; status = "Recording"
            rotation = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    guard let self, self.recording else { return }
                    self.listen()
                }
            }
        } catch {
            self.error = error.localizedDescription
            await stop()
        }
    }
    private func listen() {
        guard recording, let id = meetingID, let recognizer else { return }
        let old = currentSegment
        let segment = UUID(); currentSegment = segment
        let token = generation, offset = Date().timeIntervalSince(started)
        library.update(id, segment: segment, offset: offset, text: "", sealed: false)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true; request.taskHint = .dictation
        tasks[segment] = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            Task { @MainActor in
                guard let self, self.generation == token, self.tasks[segment] != nil else { return }
                if let result {
                    if !result.bestTranscription.formattedString.isEmpty { self.failures = 0 }
                    self.library.update(id, segment: segment, offset: offset, text: result.bestTranscription.formattedString, sealed: result.isFinal)
                }
                if result?.isFinal == true || failure != nil {
                    self.tasks.removeValue(forKey: segment)?.cancel()
                    self.seal(id, segment)
                    if failure != nil {
                        self.failures += 1
                        self.error = "Some speech could not be transcribed. The original audio is saved for reprocessing."
                        if self.failures >= 4 { await self.stop(); return }
                    }
                    if self.recording && self.currentSegment == segment { self.listen() }
                }
            }
        }
        sink?.attach(request)
        if let old {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.generation == token else { return }
                self.tasks.removeValue(forKey: old)?.cancel(); self.seal(id, old)
            }
        }
    }
    private func seal(_ id: UUID, _ segment: UUID) {
        if let part = library.documents.first(where: { $0.id == id })?.segments.first(where: { $0.id == segment }) {
            library.update(id, segment: segment, offset: part.offset, text: part.text, sealed: true)
        }
        library.checkpoint()
    }
    func stop() async {
        guard active || sink != nil else { return }
        let wasRecording = recording
        recording = false; working = true
        rotation?.cancel(); rotation = nil
        if wasRecording { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        await sink?.finish(); sink = nil
        if wasRecording { try? await Task.sleep(for: .seconds(1)) }
        generation = UUID()
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        if let meetingID { library.finish(meetingID) }
        meetingID = nil; working = false; status = "Saved"
        #if os(iOS)
        if wasRecording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    func importAudio(_ source: URL, title: String, runtime: String, kind: String = "current") {
        guard !active else { return }
        working = true; error = ""; status = "Preparing recording…"
        fileTask = Task {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() }; working = false }
            do {
                #if os(iOS)
                try await authorize()
                #endif
                let id = try library.create(title: title, runtime: runtime, kind: kind)
                meetingID = id
                let name = id.uuidString + "." + source.pathExtension
                let local = library.directory.appendingPathComponent(name)
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: source, to: local) }.value
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
                try library.audio(id, name: name)
                let reader = try AudioFileChunks(url: local)
                while let chunk = try await reader.next() {
                    defer { try? FileManager.default.removeItem(at: chunk.url) }
                    status = "Transcribing \(Int(chunk.offset)/60)m…"
                    let text = try await transcribe(chunk.url)
                    library.update(id, segment: UUID(), offset: chunk.offset, text: text, sealed: true)
                    library.checkpoint()
                    await Task.yield()
                }
                library.finish(id); meetingID = nil; status = "Transcript saved"
            } catch {
                self.error = error.localizedDescription
                if let meetingID { library.finish(meetingID) }; meetingID = nil
            }
        }
    }
    private func transcribe(_ url: URL) async throws -> String {
        #if os(macOS)
        guard let settings = Bundle.main.infoDictionary, let root = settings["AssistantRoot"] as? String, let python = settings["AssistantPython"] as? String else { throw MeetingFailure("Rebuild the app to configure local transcription.") }
        return try await Task.detached(priority: .utility) {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-m", "engine.voice.transcribe", url.path]
            child.currentDirectoryURL = URL(fileURLWithPath: root)
            child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            try child.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, let result = try JSONSerialization.jsonObject(with: data) as? [String: String], let text = result["text"] else { throw MeetingFailure("Local transcription failed. Your original recording is saved.") }
            return text
        }.value
        #else
        guard let recognizer else { throw MeetingFailure("Speech recognition is unavailable.") }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true; request.addsPunctuation = true
        let result = SpeechFileResult()
        let task = recognizer.recognitionTask(with: request) { response, error in result.receive(response, error) }
        defer { task.cancel() }
        return try await result.value()
        #endif
    }
}

private struct MeetingFailure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
private final class SpeechFileResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    func receive(_ response: SFSpeechRecognitionResult?, _ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        if let response, response.isFinal { result = .success(response.bestTranscription.formattedString) }
        else if let error { result = .failure(error) }
    }
    private func read() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    func value() async throws -> String {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if let result = read() { return try result.get() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MeetingFailure("Transcription timed out. Your original recording is saved; try importing it again.")
    }
}
actor AudioFileChunks {
    struct Chunk { let url: URL; let offset: Double }
    private let file: AVAudioFile
    init(url: URL) throws { file = try AVAudioFile(forReading: url) }
    func next() throws -> Chunk? {
        guard file.framePosition < file.length else { return nil }
        let format = file.processingFormat
        let offset = Double(file.framePosition)/format.sampleRate
        let capacity = AVAudioFrameCount(min(45*format.sampleRate, Double(file.length-file.framePosition)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048),
              let target = buffer.floatChannelData else { throw MeetingFailure("Couldn’t read the recording.") }
        var silent: Double = 0, heardSpeech = false
        while buffer.frameLength < capacity {
            try file.read(into: part, frameCount: min(2048, capacity-buffer.frameLength))
            guard part.frameLength > 0, let samples = part.floatChannelData else { break }
            var energy: Float = 0
            for channel in 0..<Int(format.channelCount) {
                memcpy(target[channel].advanced(by: Int(buffer.frameLength)), samples[channel], Int(part.frameLength)*4)
                for i in 0..<Int(part.frameLength) { energy += samples[channel][i]*samples[channel][i] }
            }
            buffer.frameLength += part.frameLength
            let level = sqrt(energy/Float(part.frameLength)/Float(format.channelCount))
            if level > 0.002 { heardSpeech = true; silent = 0 }
            else { silent += Double(part.frameLength)/format.sampleRate }
            // URL recognition may finalize at a pause. Give it one speech region at
            // a time, while retaining every sample and the original time offsets.
            if heardSpeech && silent >= 0.7 && Double(buffer.frameLength)/format.sampleRate >= 1 { break }
        }
        if !heardSpeech { return try next() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        try output.write(from: buffer)
        return Chunk(url: url, offset: offset)
    }
}
