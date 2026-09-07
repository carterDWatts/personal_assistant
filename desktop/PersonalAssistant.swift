import SwiftUI
import Speech
import AVFoundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

@MainActor
final class Chat: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var messages: [ChatMessage] = []
    @Published var draft = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "draft") }
    }
    @Published var status = "Starting…"
    @Published var memoryStatus = ""
    @Published var busy = false
    @Published var connected = false
    @Published var voice = false
    @Published var listening = false
    @Published var runtime = UserDefaults.standard.string(forKey: "runtime") ?? "claude-agent-sdk" {
        didSet { UserDefaults.standard.set(runtime, forKey: "runtime") }
    }
    @Published var test = UserDefaults.standard.bool(forKey: "testMemory") {
        didSet { UserDefaults.standard.set(test, forKey: "testMemory") }
    }
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var outputTask: Task<Void, Never>?
    private let audio = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    private let recognizer = SFSpeechRecognizer()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var silence: Timer?
    private var speechBuffer = ""
    private var streamingID: UUID?
    private var generation = UUID()
    private var listeningID = UUID()

    override init() { super.init(); speaker.delegate = self }

    func connect() {
        disconnect()
        messages = []
        let epoch = generation
        guard let settings = Bundle.main.infoDictionary,
              let root = settings["AssistantRoot"] as? String,
              let python = settings["AssistantPython"] as? String else { status = "Rebuild the app to set its engine path"; return }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = ["-m", "engine.desktop"]
        child.currentDirectoryURL = URL(fileURLWithPath: root)
        var env = ProcessInfo.processInfo.environment
        env["ASSISTANT_ENV"] = test ? "test" : "prod"
        env["PYTHONUNBUFFERED"] = "1"
        child.environment = env
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        let output = outputStream(from: stdout.fileHandleForReading)
        outputTask = Task { @MainActor [weak self] in
            for await data in output {
                guard let self = self, self.generation == epoch else { return }
                self.receive(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.generation == epoch else { return }
                self.connected = false; self.busy = false; self.stopListening(); self.status = "Disconnected · reconnect to continue"
            }
        }
        do {
            try child.run(); process = child; input = stdin.fileHandleForWriting
            busy = true; status = "Connecting…"
            write(["type": "connect", "runtime": runtime])
        } catch { status = "Could not start the engine. Rebuild the app." }
    }

    func disconnect() {
        generation = UUID()
        outputTask?.cancel(); outputTask = nil
        stopListening(); speaker.stopSpeaking(at: .immediate)
        write(["type": "quit"])
        if let child = process, child.isRunning {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if child.isRunning { child.terminate() }
            }
        }
        memoryStatus = ""
        process = nil; input = nil; buffer = Data(); connected = false; busy = false; streamingID = nil
    }

    private func write(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        do { try input?.write(contentsOf: data + Data([10])) } catch { status = "Connection closed" }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = event["type"] as? String else { continue }
            let text = event["text"] as? String ?? ""
            switch type {
            case "history":
                messages = (event["messages"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let role = row["role"] as? String, let content = row["content"] as? String else { return nil }
                    return ChatMessage(role: role, text: content)
                }
            case "ready": connected = true; busy = false; status = "Ready"; resumeListening()
            case "start":
                busy = true; speechBuffer = ""; let item = ChatMessage(role: "assistant", text: "")
                streamingID = item.id; messages.append(item); status = "Thinking…"
            case "delta":
                if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text += text }
                speechBuffer += text; speakSentences(flush: false); status = "Replying…"
            case "replace":
                if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text = text }
            case "end": speakSentences(flush: true); streamingID = nil
            case "memory": memoryStatus = text
            case "status": status = text.replacingOccurrences(of: "_", with: " ")
            case "error": busy = false; status = text; voice = false; stopListening(); speaker.stopSpeaking(at: .immediate)
            default: break
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !busy, !text.isEmpty else { return }
        stopListening(); speaker.stopSpeaking(at: .immediate)
        draft = ""; messages.append(ChatMessage(role: "user", text: text)); busy = true
        write(["type": "send", "text": text])
    }

    func stop() {
        stopListening(); speaker.stopSpeaking(at: .immediate); speechBuffer = ""
        write(["type": "stop"]); voice = false
    }

    func toggleVoice() {
        voice.toggle()
        if !voice { stopListening(); speaker.stopSpeaking(at: .immediate); status = busy ? "Replying…" : "Ready"; return }
        SFSpeechRecognizer.requestAuthorization { [weak self] result in
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                Task { @MainActor in
                    guard let self = self else { return }
                    if result == .authorized && allowed { self.resumeListening() }
                    else { self.voice = false; self.status = "Allow Microphone and Speech Recognition in System Settings" }
                }
            }
        }
    }

    private func resumeListening() {
        guard voice, connected, !busy, !speaker.isSpeaking, !listening else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else { status = "Speech recognition is unavailable"; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        let node = audio.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { status = "No microphone found"; return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        do { try audio.start() } catch { node.removeTap(onBus: 0); status = "Could not start microphone"; return }
        listening = true; status = "Listening…"
        let capture = UUID(); listeningID = capture
        recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self, self.listening, self.listeningID == capture else { return }
                if let result = result {
                    self.draft = result.bestTranscription.formattedString
                    self.silence?.invalidate()
                    if result.isFinal { self.send() }
                    else {
                        self.silence = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.send() }
                        }
                    }
                } else if error != nil { self.stopListening(); self.status = "Microphone stopped · toggle voice to retry" }
            }
        }
    }

    private func stopListening() {
        listeningID = UUID()
        silence?.invalidate(); silence = nil
        if listening { audio.stop(); audio.inputNode.removeTap(onBus: 0) }
        listening = false; request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }

    private func speakSentences(flush: Bool) {
        guard voice else { speechBuffer = ""; return }
        while let end = speechBuffer.firstIndex(where: { ".!?\n".contains($0) }) {
            let next = speechBuffer.index(after: end)
            speak(String(speechBuffer[..<next])); speechBuffer.removeSubrange(..<next)
        }
        if flush { speak(speechBuffer); speechBuffer = "" }
    }
    private func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text); utterance.rate = 0.5; speaker.speak(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeListening() }
    }
}

struct MessageText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.string != text else { return }
        let content = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: content.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        content.addAttributes([.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: paragraph], range: range)
        view.textStorage?.setAttributedString(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 600)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(24, ceil(layout.usedRect(for: container).height)))
    }
}

@MainActor struct ConversationView: View {
    @StateObject private var chat = Chat()
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Label("Personal Assistant", systemImage: "sparkle").font(.headline)
                Text("One conversation.\nShared memory.").font(.title2).foregroundColor(.secondary)
                Picker("Model", selection: $chat.runtime) {
                    Text("Claude").tag("claude-agent-sdk")
                    Text("ChatGPT").tag("codex")
                }.disabled(chat.busy)
                Toggle("Test memory", isOn: $chat.test).disabled(chat.busy)
                Spacer()
                Text(chat.test ? "Local test database" : "Personal memory in Supabase").font(.caption).foregroundColor(.secondary)
            }.padding(24).frame(width: 210).frame(maxHeight: .infinity).background(.ultraThinMaterial)
            VStack(spacing: 0) {
                HStack { Text("Conversation").font(.headline); Spacer(); Text(chat.listening ? "● Listening" : chat.busy ? "Working" : "").foregroundColor(.secondary) }.padding(24)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            if chat.messages.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("What’s on your mind?").font(.largeTitle)
                                    Text("Type a message or turn on voice to talk.").foregroundColor(.secondary)
                                }.padding(.vertical, 70)
                            }
                            ForEach(chat.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == "user" ? "You" : "Assistant").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                        Spacer()
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(message.text, forType: .string)
                                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                                        .buttonStyle(.borderless).font(.caption).disabled(message.text.isEmpty)
                                    }
                                    MessageText(text: message.text.isEmpty ? "…" : message.text)
                                }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(32).frame(maxWidth: 800).frame(maxWidth: .infinity)
                    }.onChange(of: chat.messages.last?.text) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(chat.status).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        if !chat.connected && !chat.busy {
                            Button("Retry", action: { chat.connect() })
                        }
                    }
                    if !chat.memoryStatus.isEmpty { Text(chat.memoryStatus).font(.caption).foregroundColor(.secondary) }
                    HStack(alignment: .bottom, spacing: 12) {
                        TextField("Message your assistant", text: $chat.draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).onSubmit { chat.send() }
                        Button(action: { chat.toggleVoice() }) { Image(systemName: chat.voice ? "mic.fill" : "mic") }.disabled(!chat.connected).help("Voice conversation")
                        if chat.busy || chat.voice { Button(action: { chat.stop() }) { Image(systemName: "stop.fill") }.help("Stop reply and voice") }
                        Button(action: { chat.send() }) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).disabled(chat.busy || !chat.connected || chat.draft.isEmpty).keyboardShortcut(.return, modifiers: .command)
                    }.padding(16).background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)))
                }.padding(24)
            }.frame(minWidth: 540)
        }.frame(minWidth: 840, minHeight: 620)
            .onAppear { if !chat.connected && !chat.busy { chat.connect() } }
            .onChange(of: chat.runtime) { _ in chat.connect() }
            .onChange(of: chat.test) { _ in chat.connect() }
            .onDisappear { chat.disconnect() }
    }
}

@main struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup { ConversationView() }.windowStyle(.hiddenTitleBar)
    }
}
