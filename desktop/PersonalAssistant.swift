import SwiftUI
import Darwin
import AVFoundation
import Combine

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var at: Date = Date()
}

struct PlanItem: Identifiable {
    let id = UUID()
    let item, status: String
}

private let isoFractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlain = ISO8601DateFormatter()

func parseDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return isoFractional.date(from: text) ?? isoPlain.date(from: text)
}

func plain(_ value: Any?) -> String {
    switch value {
    case nil: return ""
    case let s as String: return s
    case let b as Bool: return b ? "yes" : "no"
    case let n as NSNumber: return n.stringValue
    default: return "\(value!)"
    }
}

@MainActor
final class Chat: NSObject, ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "draft") }
    }
    @Published var status = "Starting…"
    @Published var memoryStatus = ""
    @Published var plans: [PlanItem] = []
    @Published var openQuestions = 0
    @Published var memoryPending = 0
    @Published var memoryErrors = 0
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
                self.connected = false; self.busy = false; self.voice = false; self.liveVoice.stop(); self.status = "Disconnected"
            }
        }
        do {
            try child.run(); process = child; input = stdin.fileHandleForWriting
            busy = true; status = "Connecting…"
            write(["type": "connect", "runtime": runtime, "clear": false])
        } catch { status = "Could not start the engine. Rebuild the app." }
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
                    return ChatMessage(role: role, text: content, at: parseDate(row["created_at"]) ?? Date())
                }
            case "ready":
                connected = true; busy = false; status = "Connected"
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
            case "map":
                plans = (event["plans"] as? [[String: Any]] ?? []).map { PlanItem(item: plain($0["item"]), status: plain($0["status"])) }
                openQuestions = (event["questions"] as? NSNumber)?.intValue ?? 0
                memoryPending = (event["pending"] as? NSNumber)?.intValue ?? 0
                memoryErrors = (event["errors"] as? NSNumber)?.intValue ?? 0
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

// Concrete as the material, the system's own controls on top of it, and one plant in the corner.
struct Palette {
    let background, surface, bubble, line, ink, muted, accent, moss, sage, deep: Color
    static func forScheme(_ scheme: ColorScheme) -> Palette {
        Palette(background: Color(red: 0.8, green: 0.79, blue: 0.76),
                surface: Color(red: 0.86, green: 0.855, blue: 0.83),
                bubble: Color(red: 0.73, green: 0.72, blue: 0.69),
                line: Color.black.opacity(0.22),
                ink: Color(nsColor: .labelColor),
                muted: Color(nsColor: .secondaryLabelColor),
                accent: Color(red: 0.36, green: 0.49, blue: 0.27),
                moss: Color(red: 0.27, green: 0.37, blue: 0.21),
                sage: Color(red: 0.55, green: 0.58, blue: 0.4),
                deep: Color(red: 0.17, green: 0.25, blue: 0.15))
    }
}

private let voiceInk = Color(red: 0.36, green: 0.49, blue: 0.27)

struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: Int) { state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

// Concrete grain, generated once and tiled.
private let grainImage: NSImage = {
    let size = 192
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var rng = SystemRandomNumberGenerator()
    for y in 0..<size {
        for x in 0..<size {
            let v = CGFloat(Int.random(in: 0...255, using: &rng)) / 255
            rep.setColor(NSColor(deviceRed: v, green: v, blue: v, alpha: 1), atX: x, y: y)
        }
    }
    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}()

struct Concrete: View {
    let palette: Palette
    var body: some View {
        ZStack {
            palette.background
            Canvas { context, size in
                var rng = Seeded(31)
                var stains = context
                stains.addFilter(.blur(radius: 30))
                for _ in 0..<30 {
                    let w = CGFloat.random(in: 80...260, using: &rng), h = CGFloat.random(in: 50...180, using: &rng)
                    let x = CGFloat.random(in: -40...size.width, using: &rng), y = CGFloat.random(in: -40...size.height, using: &rng)
                    let dark = Bool.random(using: &rng)
                    stains.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)),
                                with: .color((dark ? Color.black : Color.white).opacity(dark ? 0.07 : 0.06)))
                }
            }
            Image(nsImage: grainImage).resizable(resizingMode: .tile).opacity(0.11).blendMode(.overlay)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

func leaf(at point: CGPoint, length: CGFloat, angle: CGFloat) -> Path {
    var path = Path()
    let tip = CGPoint(x: point.x + cos(angle) * length, y: point.y + sin(angle) * length)
    let width = length * 0.42
    let normal = CGPoint(x: -sin(angle) * width, y: cos(angle) * width)
    let mid = CGPoint(x: (point.x + tip.x) / 2, y: (point.y + tip.y) / 2)
    path.move(to: point)
    path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x, y: mid.y + normal.y))
    path.addQuadCurve(to: point, control: CGPoint(x: mid.x - normal.x, y: mid.y - normal.y))
    return path
}

// The mark: a scaffold of four joints, one of them grown over.
struct Mark: View {
    let palette: Palette
    var lit = true
    var thinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let nodes: [CGPoint] = [CGPoint(x: 0.22, y: 0.7), CGPoint(x: 0.5, y: 0.26), CGPoint(x: 0.8, y: 0.58), CGPoint(x: 0.56, y: 0.82)]
    private let edges = [(0, 1), (1, 2), (0, 3), (3, 2)]
    private func at(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !thinking || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let tilt = thinking && !reduceMotion ? sin(time * 1.3) * 4 : 0
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                ZStack {
                    Path { path in
                        for (a, b) in edges { path.move(to: at(nodes[a], s)); path.addLine(to: at(nodes[b], s)) }
                    }.stroke(palette.ink, style: StrokeStyle(lineWidth: s * 0.08, lineCap: .square))
                    ForEach([0, 2, 3], id: \.self) { i in
                        let c = at(nodes[i], s)
                        Rectangle().fill(palette.ink).frame(width: s * 0.2, height: s * 0.2).position(c)
                    }
                    ZStack {
                        Rectangle().fill(lit ? palette.accent : palette.ink)
                            .frame(width: s * 0.3, height: s * 0.3).position(at(nodes[1], s))
                        if lit {
                            let base = at(nodes[1], s)
                            leaf(at: CGPoint(x: base.x + s * 0.1, y: base.y - s * 0.08), length: s * 0.34, angle: -0.9).fill(palette.sage)
                            leaf(at: CGPoint(x: base.x - s * 0.06, y: base.y - s * 0.12), length: s * 0.26, angle: -2.1).fill(palette.moss)
                        }
                    }
                    .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: 0.5, y: 0.41))
                }
            }.aspectRatio(1, contentMode: .fit)
        }.accessibilityHidden(true)
    }
}

// Remove the white backing when compositing the painted layer over the app material.
private let flowerBed: NSImage = {
    guard let image = NSImage(named: "FlowerBed"),
          let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let cutout = bitmap.copy(maskingColorComponents: [245, 255, 245, 255, 245, 255]) else {
        return NSImage(named: "FlowerBed") ?? NSImage()
    }
    return NSImage(cgImage: cutout, size: image.size)
}()

// The flowers stay still while the bunny looks around.
struct CornerGrowth: View {
    let palette: Palette
    var thinking = false
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack(alignment: .topLeading) {
                Mark(palette: palette, thinking: thinking)
                    .frame(width: size * 0.55, height: size * 0.55)
                    .offset(x: size * 0.22, y: size * 0.237)
                Image(nsImage: flowerBed).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }.frame(width: size, height: size)
        }.aspectRatio(1, contentMode: .fit)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let format: Date.FormatStyle = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        ? .dateTime.weekday(.wide).month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
    return date.formatted(format)
}

struct ThinkingDots: View {
    @State private var on = false
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Rectangle().fill(color).frame(width: 6, height: 6)
                    .opacity(on ? 1 : 0.2)
                    .animation(.easeInOut(duration: 0.7).repeatForever().delay(Double(i) * 0.18), value: on)
            }
        }.padding(.vertical, 8).onAppear { on = true }
    }
}

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
                    Rectangle().fill(voiceInk.opacity(0.65 + center * 0.3))
                        .frame(width: 14, height: 22 + center * 38 + min(1, level) * center * 45 + breath)
                }
            }.frame(width: 160, height: 116)
        }.accessibilityHidden(true)
    }
}

struct DayMarker: View {
    let date: Date
    let palette: Palette
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(palette.line).frame(height: 1)
            Text(dayLabel(date)).font(.caption).foregroundStyle(palette.muted).fixedSize()
            Rectangle().fill(palette.line).frame(height: 1)
        }.padding(.vertical, 4)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let palette: Palette
    @State private var hovering = false
    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 80)
                Text(inlineMarkdown(message.text))
                    .font(.body).lineSpacing(3).foregroundStyle(palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(palette.bubble)
                    .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Mark(palette: palette).frame(width: 24, height: 24).padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty {
                    ThinkingDots(color: palette.accent)
                } else {
                    Text(inlineMarkdown(message.text))
                        .font(.system(size: 15)).lineSpacing(5).foregroundStyle(palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text(message.at.formatted(.dateTime.hour().minute())).font(.caption).foregroundStyle(palette.muted)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).controlSize(.small).help("Copy").accessibilityLabel("Copy message")
                }.opacity(hovering && !message.text.isEmpty ? 1 : 0)
                }
            }.padding(.trailing, 24)
            .onHover { hovering = $0 }
        }
    }
}

struct Composer: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    @FocusState private var focused: Bool
    private var canSend: Bool { chat.connected && !chat.busy && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { chat.toggleVoice() } label: {
                Image(systemName: chat.voice ? "waveform" : "mic").frame(width: 16)
            }.buttonStyle(.bordered).controlSize(.large).tint(chat.voice ? palette.accent : nil)
                .disabled(!chat.connected).help(chat.voice ? "End the voice conversation" : "Talk instead of typing")
            TextField(chat.messages.isEmpty ? "Say anything." : "Reply", text: $chat.draft, axis: .vertical)
                .lineLimit(1...8).textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(palette.ink)
                .focused($focused).onSubmit { chat.send() }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(palette.surface)
                .overlay(Rectangle().stroke(focused ? palette.accent : palette.line, lineWidth: 1))
            if chat.busy {
                Button { chat.stop() } label: { Image(systemName: "stop.fill").frame(width: 16) }
                    .buttonStyle(.bordered).controlSize(.large).help("Stop").accessibilityLabel("Stop reply")
            } else {
                Button { chat.send() } label: { Image(systemName: "arrow.up").frame(width: 16) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(palette.accent)
                    .disabled(!canSend).keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send message")
            }
        }
        .onAppear { focused = true }
        .onChange(of: chat.connected) { if $0 { focused = true } }
    }
}

struct DayPanel: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    private var state: String {
        if chat.memoryErrors > 0 { return "Memory paused" }
        if chat.memoryPending > 0 { return "Remembering" }
        return "Memory up to date"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Date().formatted(.dateTime.weekday(.wide))).font(.title2.weight(.semibold)).foregroundStyle(palette.ink)
            Text(Date().formatted(.dateTime.month(.wide).day())).font(.subheadline).foregroundStyle(palette.muted).padding(.top, 2)
            Rectangle().fill(palette.line).frame(height: 1).padding(.vertical, 12)
            if chat.plans.isEmpty {
                Text("Nothing planned. Say what you're doing and it will keep track.")
                    .font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(chat.plans) { plan in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: plan.status == "done" ? "checkmark.square.fill" : plan.status == "proposed" ? "square.dashed" : "square")
                            .foregroundStyle(plan.status == "done" || plan.status == "proposed" ? palette.accent : palette.muted)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(plan.item).font(.callout).foregroundStyle(plan.status == "skipped" || plan.status == "dropped" ? palette.muted : palette.ink)
                                .strikethrough(plan.status == "skipped" || plan.status == "dropped").lineLimit(2)
                            if plan.status == "proposed" { Text("Suggested").font(.caption).foregroundStyle(palette.accent) }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(chat.memoryErrors > 0 ? Color.orange : chat.memoryPending > 0 ? palette.accent : palette.muted).frame(width: 6, height: 6)
                Text(state).font(.caption).foregroundStyle(palette.muted)
            }.padding(.top, 16)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface.opacity(0.55))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CornerGrowth(palette: palette, thinking: chat.busy)
                .frame(maxWidth: 260).padding(.horizontal, 4)
        }
    }
}

struct SettingsPopover: View {
    @ObservedObject var chat: Chat
    var body: some View {
        Form {
            Picker("Model", selection: $chat.runtime) {
                Text("Claude").tag("claude-agent-sdk")
                Text("ChatGPT").tag("codex")
            }.pickerStyle(.segmented).disabled(chat.busy || chat.voice)
            Toggle("Use the test memory", isOn: $chat.test).disabled(chat.busy || chat.voice)
            Text("Changing either reconnects. The conversation continues either way.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).frame(width: 300).padding(4)
    }
}

@MainActor struct VoiceConversation: View {
    @ObservedObject var chat: Chat
    let palette: Palette
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
                Text("Voice").font(.headline).foregroundStyle(palette.ink)
                Spacer()
                Button { chat.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("End voice conversation")
            }.padding(14)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty {
                            VStack(spacing: 6) {
                                VoicePresence(level: chat.liveVoice.inputLevel, moving: false).scaleEffect(0.5).frame(height: 72)
                                Text("Listening.").font(.title3).foregroundStyle(palette.ink)
                            }.frame(maxWidth: .infinity).padding(.top, 8)
                        }
                        ForEach(messages) { message in
                            HStack {
                                if message.role == "user" { Spacer(minLength: 46) }
                                Group {
                                    if message.text.isEmpty { ThinkingDots(color: palette.accent) }
                                    else { Text(inlineMarkdown(message.text)) }
                                }
                                .font(.body).lineSpacing(4).foregroundStyle(palette.ink).textSelection(.enabled)
                                .padding(message.role == "user" ? 10 : 0)
                                .background(message.role == "user" ? palette.bubble : .clear)
                                .overlay(Rectangle().stroke(message.role == "user" ? palette.line : .clear, lineWidth: 1))
                                if message.role != "user" { Spacer(minLength: 12) }
                            }
                        }
                        Color.clear.frame(height: 1).id("voice-bottom")
                    }.padding(.horizontal, 18).padding(.bottom, 12)
                }
                .onChange(of: chat.messages.last?.text) { _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
            }
            VStack(spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(chat.spokenDraft).font(.body).italic().lineSpacing(4).foregroundStyle(palette.ink)
                                .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: .infinity)
                            Color.clear.frame(height: 1).id("live-words")
                        }
                    }.frame(height: 44)
                        .onChange(of: chat.spokenDraft) { _ in proxy.scrollTo("live-words", anchor: .bottom) }
                }
                HStack(spacing: 10) {
                    Image(systemName: chat.liveVoice.speaking ? "waveform" : "mic.fill").foregroundStyle(palette.accent)
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink)
                    Spacer()
                    Button("Done") { chat.stop() }.buttonStyle(.bordered)
                }
            }.padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }.frame(width: 360, height: 350).background(palette.surface)
    }
}

@MainActor struct ConversationView: View {
    @StateObject private var chat = Chat()
    @State private var followConversation = true
    @State private var showMemory = true
    @State private var showSettings = false
    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette.forScheme(scheme) }
    private let column: CGFloat = 680

    var body: some View {
        HSplitView {
            conversation.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            if showMemory {
                DayPanel(chat: chat, palette: palette).frame(minWidth: 220, idealWidth: 260, maxWidth: 340, maxHeight: .infinity)
            }
        }
        .background(Concrete(palette: palette))
        .frame(minWidth: 860, minHeight: 580)
        .navigationTitle("Assistant")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Mark(palette: palette).frame(width: 22, height: 22)
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 6) {
                    Circle().fill(chat.connected ? palette.accent : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(chat.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !chat.connected && !chat.busy { Button("Reconnect") { chat.connect() }.controlSize(.small) }
                }
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }.help("Settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(chat: chat) }
                Button { withAnimation(.easeInOut(duration: 0.2)) { showMemory.toggle() } } label: { Image(systemName: "sidebar.right") }
                    .help(showMemory ? "Hide the day" : "Show the day")
            }
        }
        .toolbarBackground(palette.background, for: .windowToolbar)
        .preferredColorScheme(.light)
        .onAppear { if !chat.connected && !chat.busy { chat.connect() } }
        .onChange(of: chat.runtime) { _ in chat.connect() }
        .onChange(of: chat.test) { _ in chat.connect() }
        .overlay(alignment: .bottomTrailing) {
            if chat.voice {
                VoiceConversation(chat: chat, palette: palette)
                    .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.trailing, showMemory ? 280 : 22).padding(.bottom, 86)
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

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Say anything.").font(.title2).foregroundStyle(palette.ink)
                                Text("It keeps what matters, on every device, and picks the thread back up wherever you are.")
                                    .font(.callout).foregroundStyle(palette.muted).frame(maxWidth: 420, alignment: .leading)
                            }.padding(.top, 80)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].at, inSameDayAs: message.at) {
                                DayMarker(date: message.at, palette: palette)
                            }
                            MessageRow(message: message, palette: palette).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { followConversation = true }
                            .onDisappear { followConversation = false }
                    }.padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 14)
                        .frame(maxWidth: column).frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.text) { _ in
                    if followConversation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: chat.messages.count) { _ in
                    if followConversation || chat.messages.last?.role == "user" { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !followConversation {
                        Button { proxy.scrollTo("bottom", anchor: .bottom); followConversation = true } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.bordered).padding(.bottom, 8).accessibilityLabel("Scroll to latest")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 0) {
                Composer(chat: chat, palette: palette)
                    .frame(maxWidth: column).frame(maxWidth: .infinity)
                    .padding(.leading, 32).padding(.trailing, showMemory ? 32 : 8).padding(.bottom, 16)
                if !showMemory {
                    CornerGrowth(palette: palette, thinking: chat.busy).frame(width: 160, height: 160)
                }
            }
        }
    }
}

@main struct PersonalAssistantApp: App {
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        WindowGroup { ConversationView() }
    }
}
