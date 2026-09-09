import SwiftUI
import AVFoundation

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
    let palette: Palette
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let unit: CGFloat = compact ? 0.4 : 1
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || !moving)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8 * unit) {
                ForEach(0..<5) { index in
                    let center = 1 - abs(Double(index) - 2) / 3
                    let breath = moving && !reduceMotion ? (sin(time * 2 + Double(index) * 0.6) + 1) * 5 : 0
                    Rectangle().fill(palette.accent.opacity(0.65 + center * 0.3))
                        .frame(width: 14 * unit, height: (22 + center * 38 + min(1, level) * center * 45 + breath) * unit)
                }
            }.frame(width: 160 * unit, height: 116 * unit)
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

struct MessageRow: View, Equatable {
    var onReply: (() -> Void)? = nil
    let message: ChatMessage
    let palette: Palette
    static func == (a: MessageRow, b: MessageRow) -> Bool { a.message.id == b.message.id && a.message.text == b.message.text && a.message.pending == b.message.pending }
    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 56)
                Text(inlineMarkdown(message.text))
                    .font(.body).lineSpacing(3).foregroundStyle(palette.ink)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(palette.bubble)
                    .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
                    .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                            if message.reference != nil { Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply?() } }
                        }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Mark(palette: palette).frame(width: 22, height: 22).padding(.top, 2)
                if message.pending && message.text.isEmpty {
                    ThinkingDots(color: palette.accent)
                } else {
                    Text(inlineMarkdown(message.text))
                        .font(.body).lineSpacing(5).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                            if message.reference != nil { Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply?() } }
                        }
                }
            }.padding(.trailing, 12)
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
            if !chat.voice {
                Button { focused = false; chat.toggleVoice() } label: { Image(systemName: "mic") }
                    .buttonStyle(SquareButton(palette: palette)).disabled(!chat.connected).accessibilityLabel("Talk instead of typing")
            }
            TextField(chat.messages.isEmpty ? "Say anything." : "Reply", text: $chat.draft, axis: .vertical)
                .lineLimit(1...6).font(.body).foregroundStyle(palette.ink).tint(palette.accent)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(palette.surface)
                .overlay(Rectangle().stroke(focused ? palette.accent : palette.line, lineWidth: 1))
            if chat.busy {
                Button { chat.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(SquareButton(palette: palette)).accessibilityLabel("Stop reply")
            } else {
                Button { chat.send() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(SquareButton(palette: palette, prominent: true)).disabled(!canSend).accessibilityLabel("Send message")
            }
        }
    }
}

struct DayPanel: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    @Environment(\.dismiss) private var dismiss
    private var state: String {
        if chat.memoryErrors > 0 { return "Memory paused" }
        if chat.memoryPending > 0 { return "Remembering" }
        return "Memory up to date"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DaySchedule(payload: chat.calendar, ink: palette.ink, muted: palette.muted, accent: palette.accent)
                Divider()
                Button { chat.startMorning(); dismiss() } label: { Label("Start morning", systemImage: "sun.horizon") }
                .buttonStyle(.bordered).tint(palette.accent).disabled(!chat.connected || chat.busy)
                DisclosureGroup("Reminders") { ReminderPanel(chat: chat).padding(.top, 10) }
                if !chat.attention.isEmpty {
                    DisclosureGroup("What I noticed") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(chat.attention) { item in
                                    Button {
                                        chat.discussNotification(kind: "notice", id: item.id, title: item.title)
                                        dismiss()
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.title).font(.callout)
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                            Text("Talk about this").font(.caption).foregroundStyle(palette.accent)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(maxHeight: 180)
                    }.padding(.bottom, 12)
                }
                DisclosureGroup("Plan notes") {
                    if chat.plans.isEmpty {
                        Text("Nothing planned. Tell me what you’re doing and I’ll keep track.")
                        .font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
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
                }
                HStack(spacing: 6) {
                    Circle().fill(chat.memoryErrors > 0 ? Color.orange : chat.memoryPending > 0 ? palette.accent : palette.muted).frame(width: 6, height: 6)
                    Text(state).font(.caption).foregroundStyle(palette.muted)
                }.padding(.top, 16)
                CornerGrowth(palette: palette, thinking: chat.busy)
                .frame(width: 100, height: 100).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Concrete(palette: palette).ignoresSafeArea())
    }
}

/// Voice lives in the same conversation: words build here, land as bubbles, and replies stream above.
struct VoiceBar: View {
    @ObservedObject var chat: Chat
    @ObservedObject var voice: LiveVoice
    let palette: Palette
    @Binding var typing: Bool
    private var title: String {
        if voice.speaking { return "Speaking" }
        if chat.busy { return "Thinking" }
        if voice.muted { return "Muted" }
        if !voice.transcript.isEmpty { return "Listening" }
        return voice.ready ? "Go ahead" : "Starting"
    }
    private var draft: String {
        [chat.pendingSpeech, voice.transcript.isEmpty ? nil : voice.transcript].compactMap { $0 }.joined(separator: " ")
    }
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if draft.isEmpty {
                    Text(title).font(.subheadline).foregroundStyle(palette.muted)
                } else {
                    LiveTranscript(text: draft, color: palette.ink)
                }
            }
            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 24)
            HStack(spacing: 12) {
                Button { chat.toggleMute() } label: { Image(systemName: voice.muted ? "mic.slash.fill" : "mic.slash") }
                    .buttonStyle(SquareButton(palette: palette, prominent: voice.muted))
                    .accessibilityLabel(voice.muted ? "Unmute microphone" : "Mute microphone")
                Spacer()
                VoicePresence(level: voice.inputLevel, moving: voice.speaking || chat.busy, palette: palette, compact: true)
                Spacer()
                Button { typing.toggle() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(SquareButton(palette: palette)).accessibilityLabel("Type instead")
                Button { chat.stop() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SquareButton(palette: palette)).accessibilityLabel("End the voice conversation")
            }
        }
    }
}

private struct TranscriptHeight: PreferenceKey {
    static var defaultValue: CGFloat = 24
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct LiveTranscript: View {
    let text: String
    let color: Color
    @State private var contentHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var maximumHeight: CGFloat = 150

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(text).font(.body).italic().lineSpacing(3).foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(height: 1).id("transcript-end")
                }
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptHeight.self, value: geometry.size.height)
                })
            }
            .frame(height: min(max(24, contentHeight), maximumHeight))
            .onPreferenceChange(TranscriptHeight.self) { contentHeight = $0 }
            .onChange(of: contentHeight) { proxy.scrollTo("transcript-end", anchor: .bottom) }
            .onChange(of: text) { proxy.scrollTo("transcript-end", anchor: .bottom) }
            .accessibilityLabel("Live transcript")
        }
    }
}

/// A breath of olive under the conversation while voice is on, stronger when either side is speaking.
struct VoiceGlow: View {
    @ObservedObject var voice: LiveVoice
    let palette: Palette
    var body: some View {
        let strength = 0.28 + (voice.speaking ? 0.3 : 0) + min(1, voice.inputLevel) * 0.35
        LinearGradient(colors: [palette.accent.opacity(0), palette.accent.opacity(strength)], startPoint: .top, endPoint: .bottom)
            .frame(height: 260)
            .animation(.easeOut(duration: 0.25), value: strength)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    @AppStorage("voice") private var voice = ""
    @AppStorage("hostedVoice") private var hostedVoice = ""
    @AppStorage("onDeviceRecognition") private var onDevice = true
    @Environment(\.dismiss) private var dismiss
    @State private var preview = AVSpeechSynthesizer()
    @StateObject private var hostedPreview = VoicePreview()
    var body: some View {
        NavigationStack {
            List {
                Section("Model") {
                    Picker("Model", selection: $chat.selectedModel) {
                        Text("Host default").tag("")
                        ForEach(chat.models) { model in Text(model.name).tag(model.id) }
                    }.disabled(chat.busy)
                    Text("Available subscription models. Changes apply to your next message; memory stays shared.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !chat.models.contains(where: { $0.id.hasPrefix("claude-agent-sdk/") }) {
                        Text("Claude isn’t signed in on the host yet.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if chat.hostSpeaks {
                    Section("Speech") {
                        Picker("Voice", selection: $hostedVoice) {
                            Text("Michael · default").tag("")
                            ForEach(chat.hostVoices) { choice in Text(choice.name).tag(choice.id) }
                        }
                        .onChange(of: hostedVoice) { _, choice in
                            hostedPreview.play(choice, voice: chat.liveVoice) { !chat.busy && !chat.liveVoice.speaking }
                        }
                        Button("Hear it again") {
                            hostedPreview.play(hostedVoice, voice: chat.liveVoice) { !chat.busy && !chat.liveVoice.speaking }
                        }
                        if !hostedPreview.status.isEmpty {
                            Text(hostedPreview.status).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Changes apply to the next reply. All voices use Pocket TTS on your host.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .onDisappear { hostedPreview.stop() }
                } else {
                Section {
                    Picker("Voice", selection: $voice) {
                        Text("Best available").tag("")
                        ForEach(LiveVoice.candidates, id: \.identifier) { candidate in
                            Text("\(candidate.name), \(LiveVoice.qualityLabel(candidate))").tag(candidate.identifier)
                        }
                    }.pickerStyle(.navigationLink)
                    Button("Hear it") {
                        let utterance = AVSpeechUtterance(string: "Morning. Nothing is on the calendar until the afternoon.")
                        utterance.voice = LiveVoice.voice
                        preview.stopSpeaking(at: .immediate)
                        preview.speak(utterance)
                    }
                } header: { Text("Speech") } footer: {
                    Text("Premium voices are downloads under Settings › Accessibility › Spoken Content › Voices. They sound far better than the built-in ones.")
                }
                }
                Section {
                    Toggle("Recognize speech on this phone", isOn: $onDevice)
                } footer: {
                    Text("On-device recognition avoids network delays. Turn this off to try network recognition. Applies when you next start Talk.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(palette.accent)
    }
}

struct SignInView: View {
    let palette: Palette
    @ObservedObject private var account = Account.shared
    @State private var email = UserDefaults.standard.string(forKey: "email") ?? ""
    @State private var sent = false
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Mark(palette: palette).frame(width: 64, height: 64)
            Text(AssistantIdentity.name).font(.largeTitle.weight(.semibold)).foregroundStyle(palette.ink)
            Text(sent ? "Open the email on this phone and tap the link. It brings you back here signed in."
                      : "Sign in with the address on the account. A link will be emailed to you.")
                .font(.callout).foregroundStyle(palette.muted)
            if !sent {
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body).foregroundStyle(palette.ink).tint(palette.accent)
                    .padding(12).background(palette.surface).overlay(Rectangle().stroke(palette.line, lineWidth: 1))
            }
            if !account.problem.isEmpty { Text(account.problem).font(.caption).foregroundStyle(Color.orange) }
            HStack {
                if sent { Button("Use another address") { sent = false; account.problem = "" }.foregroundStyle(palette.muted) }
                Spacer()
                Button { Task { await send() } } label: { Text(sent ? "Send again" : "Send link").padding(.horizontal, 10) }
                    .buttonStyle(SquareButton(palette: palette, prominent: true))
                    .disabled(working || !email.contains("@"))
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Concrete(palette: palette).ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    private func send() async {
        working = true; account.problem = ""
        defer { working = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        do {
            try await account.requestLink(email: address)
            UserDefaults.standard.set(address, forKey: "email")
            sent = true
        } catch {
            account.problem = error.localizedDescription
        }
    }
}

struct ConversationView: View {
    @StateObject private var chat = Chat()
    @ObservedObject private var account = Account.shared
    @State private var follow = true
    @State private var showDay = false
    @State private var showSettings = false
    @State private var showConnections = false
    @State private var showImport = false
    @State private var typing = false
    @Environment(\.scenePhase) private var phase
    private let palette = Palette.concrete
    private let sample = ProcessInfo.processInfo.arguments.contains("--sample")

    var body: some View {
        VStack(spacing: 0) {
            header
            conversation
                .overlay(alignment: .bottom) {
                    if chat.voice { VoiceGlow(voice: chat.liveVoice, palette: palette) }
                }
            if let selection = chat.notificationDiscussion {
                HStack {
                    Label("Replying to \(AssistantIdentity.name): " + (selection["title"] ?? ""), systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(2)
                    Spacer()
                    Button { chat.clearNotificationDiscussion() } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel reply")
                }.padding(12).background(palette.surface).padding(.horizontal,16)
            }
            if chat.voice {
                if typing { Composer(chat: chat, palette: palette).padding(.horizontal, 16).padding(.bottom, 10) }
                VoiceBar(chat: chat, voice: chat.liveVoice, palette: palette, typing: $typing).padding(.horizontal, 16).padding(.bottom, 10)
            } else {
                if chat.busy || !chat.connected {
                    Text(chat.status).font(.caption).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }
                Composer(chat: chat, palette: palette).padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chat.voice)
        .background(Concrete(palette: palette).equatable().ignoresSafeArea())
        .tint(palette.accent)
        .sheet(isPresented: $showDay) {
            DayPanel(chat: chat, palette: palette).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) { SettingsView(chat: chat, palette: palette) }
        .sheet(isPresented: $showImport) { ContextImportView(upload: chat.importPart, refresh: chat.imports, runtime: chat.selectedModel.hasPrefix("claude-agent-sdk/") ? "claude-agent-sdk" : "codex") }
        .sheet(isPresented: $showConnections) { ConnectionsView(chat: chat, palette: palette) }
        .sheet(isPresented: Binding(get: { chat.tokenForm != nil }, set: { if !$0 { chat.tokenForm = nil } })) {
            if let provider = chat.tokenForm { TokenForm(chat: chat, provider: provider, palette: palette) }
        }
        .fullScreenCover(isPresented: Binding(get: { !account.signedIn && !sample }, set: { _ in })) { SignInView(palette: palette) }
        .onAppear { if !chat.connected && !chat.busy { chat.connect() } }
        .onChange(of: account.signedIn) { _, now in if now { chat.connect() } }
        .onOpenURL { url in
            if !WebAuth.shared.receive(url) { Task { await account.open(url) } }
        }
        .onChange(of: phase) { _, now in chat.foreground(now == .active) }
        .preferredColorScheme(.light)
    }

    // Drawn here rather than in the system bar, which wraps items in glass and clips them on iOS 26.
    private var header: some View {
        HStack(spacing: 10) {
            Mark(palette: palette, thinking: chat.busy).frame(width: 24, height: 24)
            Menu {
                Picker("Model", selection: $chat.selectedModel) {
                    Text("Host default").tag("")
                    ForEach(chat.models) { model in Text(model.name).tag(model.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(AssistantIdentity.name).font(.headline)
                    Image(systemName: "chevron.down").font(.caption2)
                }.foregroundStyle(palette.ink)
            }.disabled(chat.busy || chat.models.isEmpty).accessibilityLabel("Choose model")
            Spacer()
            Circle().fill(chat.connected ? palette.accent : palette.muted).frame(width: 7, height: 7).accessibilityLabel(chat.status).padding(.trailing, 4)
            Button { showDay = true } label: { Label("Calendar", systemImage: "calendar").font(.subheadline) }
                .buttonStyle(.bordered).tint(palette.accent).accessibilityLabel("Open calendar")
            Menu {
                Button("Clear", systemImage: "eraser") { chat.draft = ""; chat.connect(clear: true) }.disabled(!chat.connected || chat.busy)
                Button("Start morning", systemImage: "sun.horizon") { chat.startMorning() }.disabled(!chat.connected || chat.busy)
                Button("Import context", systemImage: "doc.badge.plus") { showImport = true }
                Button("Connections", systemImage: "link") { showConnections = true }
                Button("Settings", systemImage: "gearshape") { showSettings = true }
                if !chat.connected && !chat.busy { Button("Reconnect", systemImage: "arrow.clockwise") { chat.connect() } }
                if account.signedIn { Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { account.signOut() } }
            } label: { Image(systemName: "ellipsis") }
            .buttonStyle(SquareButton(palette: palette, size: 36))
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .background(palette.background.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if chat.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("I’m \(AssistantIdentity.name). What’s on your mind?").font(.title2).foregroundStyle(palette.ink)
                            Text("I keep what matters, on every device, and pick the thread back up wherever you are.")
                                .font(.callout).foregroundStyle(palette.muted)
                        }.padding(.top, 60)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].at, inSameDayAs: message.at) {
                            DayMarker(date: message.at, palette: palette)
                        }
                        MessageRow(onReply: { chat.reply(to: message) }, message: message, palette: palette).equatable().id(message.id)
                    }
                    if let prompt = chat.connectionPrompt {
                        ConnectionCard(chat: chat, prompt: prompt, palette: palette)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { follow = true }
                        .onDisappear { follow = false }
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.focusedMessage) { if let id = chat.focusedMessage { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: chat.messages.last?.text) { if follow { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.messages.count) {
                if follow || chat.messages.last?.role == "user" { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !follow {
                    Button { proxy.scrollTo("bottom", anchor: .bottom); follow = true } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(SquareButton(palette: palette)).padding(.bottom, 8).accessibilityLabel("Scroll to latest")
                }
            }
        }
    }
}

/// A connection prompt that disappears once access is granted.
struct ConnectionCard: View {
    @ObservedObject var chat: Chat
    let prompt: ConnectionPrompt
    let palette: Palette
    private var service: String { Service.name(prompt.provider, grant: prompt.grant) }
    private var detail: String {
        switch prompt.phase {
        case .failed(let text): return text
        case .connecting: return Service.usesToken(prompt.provider) ? "Checking the token." : "Finish in the sheet; the host keeps the permission and this phone never sees the token."
        case .needed: return Service.usesToken(prompt.provider)
            ? "Guided setup with a token you paste. The assistant only reads."
            : "Approve it in a secure sheet. The host keeps the permission and this phone never sees the token."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(palette.accent)
                Text("\(service) isn’t connected for the host")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink)
            }
            Text(detail).font(.callout).foregroundStyle({ if case .failed = prompt.phase { return Color.orange } else { return palette.muted } }())
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                switch prompt.phase {
                case .needed, .failed:
                    Button { chat.connectService() } label: { Text("Connect \(Service.name(prompt.provider))").padding(.horizontal, 10) }
                        .buttonStyle(SquareButton(palette: palette, prominent: true))
                case .connecting:
                    ProgressView().tint(palette.accent)
                    Text("Waiting for \(Service.name(prompt.provider))…").font(.callout).foregroundStyle(palette.muted)

                }
            }
        }
        .padding(14)
        .background(palette.surface.opacity(0.85))
        .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
        .padding(.leading, 32)
    }
}

/// Guided token setup for the services without a sign-in flow. The token goes to the host's secure setup path only.
struct TokenForm: View {
    @ObservedObject var chat: Chat
    let provider: String
    let palette: Palette
    @State private var token = ""
    @State private var working = false
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(Service.instructions(provider)).font(.callout).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                SecureField("Token", text: $token).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.body.monospaced()).foregroundStyle(palette.ink).tint(palette.accent)
                    .padding(12).background(palette.surface).overlay(Rectangle().stroke(palette.line, lineWidth: 1))
                if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(Color.orange) }
                HStack {
                    Spacer()
                    Button {
                        Task {
                            working = true
                            problem = await chat.submitToken(provider: provider, token: token.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                            working = false
                            if problem.isEmpty { dismiss() }
                        }
                    } label: { Text(working ? "Checking…" : "Save").padding(.horizontal, 10) }
                    .buttonStyle(SquareButton(palette: palette, prominent: true)).disabled(working || token.count < 8)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Concrete(palette: palette).ignoresSafeArea())
            .navigationTitle(Service.name(provider)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(palette.accent).preferredColorScheme(.light)
    }
}

/// Every service the host can read from, with its state on the host, not on this phone.
struct ConnectionsView: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    @State private var working: String? = nil
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss
    @State private var tokenProvider: String?
    private func connection(_ provider: String) -> Connection? { chat.connections.first { $0.id == provider } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Service.grants, id: \.self) { grant in
                        let linked = connection("google")?.grants.contains(grant) == true
                        row(Service.name("google", grant: grant), linked: linked, configured: connection("google")?.configured ?? false, key: "google/" + grant) {
                            if linked { chat.disconnect("google", grant: grant) } else { authorize("google", grant) }
                        }
                    }
                } header: { Text("Google") } footer: { Text(connection("google")?.account.map { "Signed in as \($0)." } ?? "Each permission is approved separately.") }
                Section {
                    ForEach(IntegrationCatalog.accounts.map(\.id), id: \.self) { provider in
                        let linked = connection(provider)?.state == "connected"
                        row(Service.name(provider), linked: linked, configured: connection(provider)?.configured ?? false, key: provider) {
                            if linked { chat.disconnect(provider) } else if Service.usesToken(provider) { tokenProvider = provider } else { authorize(provider, nil) }
                        }
                    }
                } header: { Text("Apps") } footer: { Text("Each service uses its supported sign-in or secure setup flow. Disconnect removes the saved connection.") }
                if !chat.connectionError.isEmpty { Section { Text(chat.connectionError).font(.caption).foregroundStyle(Color.orange) } }
                if !problem.isEmpty { Section { Text(problem).font(.caption).foregroundStyle(Color.orange) } }
            }
            .scrollContentBackground(.hidden)
            .background(palette.background)
            .sheet(isPresented: Binding(get: { tokenProvider != nil }, set: { if !$0 { tokenProvider = nil } })) {
                if let provider = tokenProvider { TokenForm(chat: chat, provider: provider, palette: palette) }
            }
            .navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { chat.refreshConnections() }
        }.tint(palette.accent).preferredColorScheme(.light)
    }

    private func row(_ name: String, linked: Bool, configured: Bool, key: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: linked ? "checkmark.square.fill" : "square").foregroundStyle(linked ? palette.accent : palette.muted)
            Text(name).foregroundStyle(palette.ink)
            Spacer()
            if working == key { ProgressView().tint(palette.accent) }
            else if !linked && !configured { Text("Setup unavailable").font(.caption).foregroundStyle(palette.muted) }
            else { Button(linked ? "Disconnect" : "Connect", action: action).disabled(working != nil).font(.callout).foregroundStyle(linked ? palette.muted : palette.accent) }
        }
    }

    private func authorize(_ provider: String, _ grant: String?) {
        working = provider + "/" + (grant ?? ""); problem = ""
        Task {
            do { try await chat.authorize(provider: provider, grant: grant) } catch { problem = error.localizedDescription }
            working = nil
        }
    }
}

struct ReminderPanel: View {
    @ObservedObject var chat: Chat
    @State private var notificationStatus = "Enable reminder notifications"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders").font(.headline)
            Button(notificationStatus) {
                if notificationStatus.contains("Settings"), let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                else { Notifications.shared?.enable() }
            }.font(.caption)
            if !chat.reminderStatus.isEmpty { Text(chat.reminderStatus).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.reminders) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.callout)
                            if item.severity != "normal" { Text(item.severity.capitalized + " importance").font(.caption2).foregroundStyle(.secondary) }
                            if !item.context.isEmpty { Text(item.context).font(.caption).foregroundStyle(.secondary) }
                            if let next = item.next { Text("Next check: " + next.formatted(date: .abbreviated, time: .shortened)).font(.caption2) }
                            HStack {
                                Button("Done") { chat.reminderAction(item, action: "done") }
                                Button("In an hour") { chat.reminderAction(item, action: "snooze") }
                            }.font(.caption).buttonStyle(.bordered)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 200)
        }.task {
            await Notifications.shared?.refresh()
            while !Task.isCancelled {
                notificationStatus = Notifications.shared?.status ?? "Enable reminder notifications"
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
