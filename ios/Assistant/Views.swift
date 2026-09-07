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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || !moving)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    let center = 1 - abs(Double(index) - 2) / 3
                    let breath = moving && !reduceMotion ? (sin(time * 2 + Double(index) * 0.6) + 1) * 5 : 0
                    Rectangle().fill(palette.accent.opacity(0.65 + center * 0.3))
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
    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 56)
                Text(inlineMarkdown(message.text))
                    .font(.body).lineSpacing(3).foregroundStyle(palette.ink)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(palette.bubble)
                    .overlay(Rectangle().stroke(palette.line, lineWidth: 1))
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Mark(palette: palette).frame(width: 22, height: 22).padding(.top, 2)
                if message.text.isEmpty {
                    ThinkingDots(color: palette.accent)
                } else {
                    Text(inlineMarkdown(message.text))
                        .font(.body).lineSpacing(5).foregroundStyle(palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text } }
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
            Button { focused = false; chat.toggleVoice() } label: { Image(systemName: chat.voice ? "waveform" : "mic") }
                .buttonStyle(SquareButton(palette: palette)).disabled(!chat.connected).accessibilityLabel("Talk instead of typing")
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
            HStack(spacing: 6) {
                Circle().fill(chat.memoryErrors > 0 ? Color.orange : chat.memoryPending > 0 ? palette.accent : palette.muted).frame(width: 6, height: 6)
                Text(state).font(.caption).foregroundStyle(palette.muted)
            }.padding(.top, 16)
            Spacer(minLength: 12)
            CornerGrowth(palette: palette, thinking: chat.busy)
                .frame(width: 200, height: 200)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Concrete(palette: palette).ignoresSafeArea())
    }
}

struct VoiceConversation: View {
    @ObservedObject var chat: Chat
    let palette: Palette
    private var title: String {
        if chat.liveVoice.speaking { return "Speaking" }
        if chat.busy { return "Thinking" }
        if !chat.liveVoice.transcript.isEmpty { return "Listening" }
        return chat.liveVoice.active ? "Go ahead" : "Starting"
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.messages.dropFirst(chat.voiceStartIndex)) { message in
                            MessageRow(message: message, palette: palette)
                        }
                        Color.clear.frame(height: 1).id("voice-bottom")
                    }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 12)
                }
                .onChange(of: chat.messages.last?.text) { proxy.scrollTo("voice-bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { proxy.scrollTo("voice-bottom", anchor: .bottom) }
            }
            VStack(spacing: 14) {
                VoicePresence(level: chat.liveVoice.inputLevel, moving: chat.liveVoice.speaking || chat.busy, palette: palette)
                Text(chat.spokenDraft).font(.body).italic().lineSpacing(4).foregroundStyle(palette.ink)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 48, alignment: .top)
                HStack(spacing: 10) {
                    Image(systemName: chat.liveVoice.speaking ? "waveform" : "mic.fill").foregroundStyle(palette.accent)
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink)
                    Spacer()
                    Button { chat.stop() } label: { Text("Done").padding(.horizontal, 8) }
                        .buttonStyle(SquareButton(palette: palette))
                }
            }
            .padding(18)
            .background(palette.surface.opacity(0.85))
            .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
        }
        .background(Concrete(palette: palette).ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}

struct SettingsView: View {
    let palette: Palette
    @AppStorage("voice") private var voice = ""
    @AppStorage("onDeviceRecognition") private var onDevice = false
    @Environment(\.dismiss) private var dismiss
    @State private var preview = AVSpeechSynthesizer()
    var body: some View {
        NavigationStack {
            List {
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
                Section {
                    Toggle("Recognize speech on this phone", isOn: $onDevice)
                } footer: {
                    Text("On by default when there is no network. Recognition over the network is more accurate.")
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
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var problem = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Mark(palette: palette).frame(width: 64, height: 64)
            Text(AssistantIdentity.name).font(.largeTitle.weight(.semibold)).foregroundStyle(palette.ink)
            Text(sent ? "Enter the code from the email." : "Sign in with the address on the account. A code will be emailed to you.")
                .font(.callout).foregroundStyle(palette.muted)
            if sent {
                TextField("Code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.title3.monospacedDigit()).foregroundStyle(palette.ink).tint(palette.accent)
                    .padding(12).background(palette.surface).overlay(Rectangle().stroke(palette.line, lineWidth: 1))
            } else {
                TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body).foregroundStyle(palette.ink).tint(palette.accent)
                    .padding(12).background(palette.surface).overlay(Rectangle().stroke(palette.line, lineWidth: 1))
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(Color.orange) }
            HStack {
                if sent { Button("Use another address") { sent = false; code = ""; problem = "" }.foregroundStyle(palette.muted) }
                Spacer()
                Button { Task { await submit() } } label: { Text(sent ? "Sign in" : "Send code").padding(.horizontal, 10) }
                    .buttonStyle(SquareButton(palette: palette, prominent: true))
                    .disabled(working || (sent ? code.count < 6 : !email.contains("@")))
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Concrete(palette: palette).ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    private func submit() async {
        working = true; problem = ""
        defer { working = false }
        let address = email.trimmingCharacters(in: .whitespaces)
        do {
            if sent {
                try await account.verify(email: address, code: code.trimmingCharacters(in: .whitespaces))
                UserDefaults.standard.set(address, forKey: "email")
            } else {
                try await account.requestCode(email: address)
                sent = true
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

struct ConversationView: View {
    @StateObject private var chat = Chat()
    @ObservedObject private var account = Account.shared
    @State private var follow = true
    @State private var showDay = false
    @State private var showSettings = false
    @Environment(\.scenePhase) private var phase
    private let palette = Palette.concrete
    private let sample = ProcessInfo.processInfo.arguments.contains("--sample")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                if chat.busy || !chat.connected {
                    Text(chat.status).font(.caption).foregroundStyle(palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 6)
                }
                Composer(chat: chat, palette: palette).padding(.horizontal, 16).padding(.bottom, 10)
            }
            .background(Concrete(palette: palette).ignoresSafeArea())
            .navigationTitle(AssistantIdentity.name).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Mark(palette: palette, thinking: chat.busy).frame(width: 22, height: 22)
                        Text(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).font(.subheadline).foregroundStyle(palette.muted)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Circle().fill(chat.connected ? palette.accent : palette.muted).frame(width: 7, height: 7).accessibilityLabel(chat.status)
                    Button { showDay = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Show the day")
                    Menu {
                        Button("Clear", systemImage: "eraser") { chat.draft = ""; chat.connect(clear: true) }.disabled(!chat.connected || chat.busy)
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                        if !chat.connected && !chat.busy { Button("Reconnect", systemImage: "arrow.clockwise") { chat.connect() } }
                        if account.signedIn { Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { account.signOut() } }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .tint(palette.accent)
            .sheet(isPresented: $showDay) {
                DayPanel(chat: chat, palette: palette).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) { SettingsView(palette: palette) }
            .fullScreenCover(isPresented: Binding(get: { chat.voice }, set: { if !$0 { chat.stop() } })) {
                VoiceConversation(chat: chat, palette: palette)
            }
            .fullScreenCover(isPresented: Binding(get: { !account.signedIn && !sample }, set: { _ in })) { SignInView(palette: palette) }
            .onAppear { if !chat.connected && !chat.busy { chat.connect() } }
            .onChange(of: account.signedIn) { _, now in if now { chat.connect() } }
            .onChange(of: phase) { _, now in
                if now != .active && chat.voice { chat.stop() }
                chat.foreground(now == .active)
            }
        }
        .preferredColorScheme(.light)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if chat.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("I’m \(AssistantIdentity.name). What’s on your mind?").font(.title2).foregroundStyle(palette.ink)
                            Text("It keeps what matters, on every device, and picks the thread back up wherever you are.")
                                .font(.callout).foregroundStyle(palette.muted)
                        }.padding(.top, 60)
                    }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].at, inSameDayAs: message.at) {
                            DayMarker(date: message.at, palette: palette)
                        }
                        MessageRow(message: message, palette: palette).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { follow = true }
                        .onDisappear { follow = false }
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
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
