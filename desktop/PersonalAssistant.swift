import SwiftUI
import Darwin
import AVFoundation
import Combine

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
}

@MainActor
final class Chat: NSObject, ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "draft") }
    }
    @Published var status = "Starting…"
    @Published var memoryStatus = ""
    @Published var busy = false
    @Published var connected = false
    @Published var voice = false
    var listening: Bool { liveVoice.active }
    let liveVoice = LiveVoice()
    var spokenDraft: String {
        [voiceTurn.pending, liveVoice.transcript.isEmpty ? nil : liveVoice.transcript].compactMap { $0 }.joined(separator: " ")
    }
    private(set) var voiceStartIndex = 0
    private var voiceTurn = VoiceTurn()
    private var voiceSubscription: AnyCancellable?
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
    private var speechBuffer = ""
    private var streamingID: UUID?
    private var generation = UUID()

    override init() {
        super.init()
        voiceSubscription = liveVoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        liveVoice.onSpeech = { [weak self] in self?.interruptForSpeech() }
        liveVoice.onUtterance = { [weak self] text in self?.sendVoice(text) }
        liveVoice.onError = { [weak self] text in self?.voice = false; self?.status = text }
        liveVoice.prepare()
    }

    func connect(clear: Bool = false) {
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
                self.connected = false; self.busy = false; self.voice = false; self.liveVoice.stop(); self.status = "Disconnected · reconnect to continue"
            }
        }
        do {
            try child.run(); process = child; input = stdin.fileHandleForWriting
            busy = true; status = "Connecting…"
            write(["type": "connect", "runtime": runtime, "clear": clear])
        } catch { status = "Could not start the engine. Rebuild the app." }
    }

    func clearChat() {
        draft = ""
        voice = false
        connect(clear: true)
    }

    func disconnect() {
        generation = UUID()
        outputTask?.cancel(); outputTask = nil
        liveVoice.stop(); voice = false; voiceTurn = VoiceTurn()
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
            case "ready":
                connected = true; busy = false; status = "Ready"
                if let pending = voiceTurn.ready(), voice { submit(pending) }
            case "start":
                busy = true; speechBuffer = ""; let item = ChatMessage(role: "assistant", text: "")
                streamingID = item.id; messages.append(item); status = "Thinking…"
            case "delta":
                if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text += text }
                if !voiceTurn.interrupted { speechBuffer += text; speakSentences(flush: false); status = "Replying…" }
            case "replace":
                if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text = text }
            case "end":
                if !voiceTurn.interrupted { speakSentences(flush: true) }
                streamingID = nil
            case "memory": memoryStatus = text
            case "status": status = text.replacingOccurrences(of: "_", with: " ")
            case "error": busy = false; status = text; voice = false; liveVoice.stop(); voiceTurn = VoiceTurn()
            default: break
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !busy, !text.isEmpty else { return }
        draft = ""
        submit(text)
    }

    private func submit(_ text: String) {
        liveVoice.silencePlayback()
        speechBuffer = ""
        messages.append(ChatMessage(role: "user", text: text)); busy = true
        write(["type": "send", "text": text])
    }

    private func interruptForSpeech() {
        liveVoice.silencePlayback(); speechBuffer = ""
        voiceTurn.pausePlayback(busy: busy)
        status = "Listening…"
    }

    private func sendVoice(_ text: String) {
        guard voice, connected else { return }
        if busy {
            objectWillChange.send(); voiceTurn.queue(text); interruptForSpeech()
            if voiceTurn.interrupt(busy: busy) { write(["type": "stop"]) }
        }
        else { submit(text) }
    }

    func stop() {
        liveVoice.stop(); speechBuffer = ""; voice = false; voiceTurn.discardPending()
        if voiceTurn.interrupt(busy: busy) { write(["type": "stop"]) }
    }

    func toggleVoice() {
        if voice { stop(); return }
        voiceStartIndex = messages.count
        voice = true
        liveVoice.start()
    }

    private func speakSentences(flush: Bool) {
        guard voice else { speechBuffer = ""; return }
        while let chunk = nextSpeechChunk(&speechBuffer, flush: flush) { speak(chunk) }
    }
    private func speak(_ text: String) { liveVoice.speak(text) }

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

private let voiceInk = Color(red: 0.36, green: 0.46, blue: 0.65)

struct VoicePresence: View {
    let level: Double
    let moving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || !moving)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    let center = 1 - abs(Double(index) - 2) / 3
                    let breath = moving && !reduceMotion ? (sin(time * 2 + Double(index) * 0.6) + 1) * 5 : 0
                    Capsule().fill(voiceInk.opacity(0.65 + center * 0.3))
                        .frame(width: 16, height: 22 + center * 38 + min(1, level) * center * 45 + breath)
                }
            }.frame(width: 160, height: 116)
        }.accessibilityHidden(true)
    }
}

@MainActor struct VoiceConversation: View {
    @ObservedObject var chat: Chat
    private var title: String {
        if !chat.liveVoice.active { return chat.liveVoice.startupMessage }
        if !chat.spokenDraft.isEmpty { return "Listening" }
        if chat.liveVoice.speaking { return "Speaking" }
        return chat.busy ? "Thinking" : "Listening"
    }
    private var messages: [ChatMessage] { Array(chat.messages.dropFirst(chat.voiceStartIndex)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Voice conversation").font(.system(size: 15, weight: .semibold))
                    Text(chat.runtime == "codex" ? "ChatGPT" : "Claude").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { chat.stop() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30).background(Color.primary.opacity(0.07), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("End voice conversation")
            }.padding(16)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if messages.isEmpty {
                            VStack(spacing: 6) {
                                VoicePresence(level: chat.liveVoice.inputLevel, moving: false).scaleEffect(0.5).frame(height: 72)
                                Text("What’s on your mind?").font(.system(size: 22, design: .serif))
                            }.frame(maxWidth: .infinity).padding(.top, 8)
                        }
                        ForEach(messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 46) }
                                Text(message.text.isEmpty ? AttributedString("Thinking…") : (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.text))
                                    .font(.system(size: message.role == "user" ? 16 : 18, design: message.role == "user" ? .default : .serif))
                                    .lineSpacing(5).textSelection(.enabled)
                                    .padding(message.role == "user" ? 12 : 0)
                                    .background(message.role == "user" ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 16))
                                if message.role != "user" { Spacer(minLength: 12) }
                            }
                        }
                        Color.clear.frame(height: 1).id("voice-bottom")
                    }.padding(.horizontal, 24).padding(.bottom, 12)
                }
                .onChange(of: chat.messages.last?.text) { _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
            }
            VStack(spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(chat.spokenDraft).font(.system(size: 16)).italic().lineSpacing(4)
                                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: .infinity)
                            Color.clear.frame(height: 1).id("live-words")
                        }
                    }.frame(height: 44)
                        .onChange(of: chat.spokenDraft) { _ in proxy.scrollTo("live-words", anchor: .bottom) }
                }
                HStack(spacing: 10) {
                    Image(systemName: chat.liveVoice.speaking ? "waveform" : "mic.fill")
                        .foregroundStyle(voiceInk)
                    Text(title).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button("Done") { chat.stop() }.buttonStyle(.bordered).controlSize(.large)
                }
            }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 14)
                .background(LinearGradient(colors: [.clear, voiceInk.opacity(chat.liveVoice.speaking ? 0.12 : 0.2)], startPoint: .top, endPoint: .bottom))
        }.frame(width: 360, height: 350).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor struct ConversationView: View {
    @StateObject private var chat = Chat()
    @State private var followConversation = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Personal Assistant").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("Model", selection: $chat.runtime) {
                    Text("Claude").tag("claude-agent-sdk")
                    Text("ChatGPT").tag("codex")
                }.labelsHidden().frame(width: 112).disabled(chat.busy || chat.voice)
                Toggle("Test memory", isOn: $chat.test).toggleStyle(.switch).controlSize(.small).disabled(chat.busy || chat.voice)
                Button("Clear", action: { chat.clearChat() }).buttonStyle(.borderless)
                    .disabled(chat.busy || !chat.connected).help("Start a fresh chat. Keep memory.")
            }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("What’s on your mind?").font(.system(size: 32, weight: .medium, design: .rounded))
                                Text("Write a little. Talk it through.").font(.title3).foregroundStyle(.secondary)
                            }.padding(.vertical, 80)
                        }
                        ForEach(chat.messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 60) }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == "user" ? "You" : "Assistant").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                        Spacer()
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(message.text, forType: .string)
                                        } label: { Image(systemName: "doc.on.doc") }
                                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy message").accessibilityLabel("Copy message").disabled(message.text.isEmpty)
                                    }
                                    MessageText(text: message.text.isEmpty ? "…" : message.text)
                                }.padding(message.role == "user" ? 16 : 0)
                                    .background(message.role == "user" ? Color(nsColor: .controlBackgroundColor) : Color.clear, in: RoundedRectangle(cornerRadius: 16))
                                if message.role != "user" { Spacer(minLength: 32) }
                            }.id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { followConversation = true }
                            .onDisappear { followConversation = false }
                    }.padding(28).frame(maxWidth: 780).frame(maxWidth: .infinity)
                }.onChange(of: chat.messages.last?.text) { _ in
                    if followConversation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: chat.messages.count) { _ in
                    if followConversation || chat.messages.last?.role == "user" { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followConversation {
                        Button { proxy.scrollTo("bottom", anchor: .bottom); followConversation = true }
                            label: { Label("Latest", systemImage: "arrow.down") }
                            .buttonStyle(.bordered).padding(16)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Message your assistant", text: $chat.draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).onSubmit { chat.send() }
                        .padding(.vertical, 7)
                    if !chat.voice {
                        Button(action: { chat.toggleVoice() }) { Label("Talk", systemImage: "waveform") }
                            .buttonStyle(.bordered).disabled(!chat.connected).help("Start a live voice conversation")
                    }
                    if chat.busy { Button(action: { chat.stop() }) { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("Stop reply") }
                    Button(action: { chat.send() }) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                        .buttonStyle(.plain).foregroundStyle(chat.draft.isEmpty ? Color.secondary : Color.accentColor)
                        .disabled(chat.busy || !chat.connected || chat.draft.isEmpty).keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send message")
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .top) {
                    Text(chat.status).lineLimit(2)
                    if !chat.connected && !chat.busy { Button("Retry", action: { chat.connect() }).buttonStyle(.borderless) }
                    Spacer()
                    Text(chat.memoryStatus.isEmpty ? (chat.test ? "Test memory" : "Personal memory") : chat.memoryStatus).lineLimit(2)
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.bottom, 20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 660, minHeight: 600)
            .onAppear { if !chat.connected && !chat.busy { chat.connect() } }
            .onChange(of: chat.runtime) { _ in chat.connect() }
            .onChange(of: chat.test) { _ in chat.connect() }
            .overlay(alignment: .bottomTrailing) {
                if chat.voice {
                    VoiceConversation(chat: chat)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
                        .padding(.trailing, 22).padding(.bottom, 104)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                if chat.voice { chat.stop() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
                if chat.voice { chat.stop() }
            }
            .onDisappear { chat.disconnect() }
    }
}

@main struct PersonalAssistantApp: App {
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        WindowGroup { ConversationView() }.windowStyle(.hiddenTitleBar)
    }
}
