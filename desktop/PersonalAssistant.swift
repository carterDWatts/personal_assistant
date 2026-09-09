import SwiftUI
import Darwin

enum AssistantIdentity {
    static let name: String = {
        guard let url = Bundle.main.url(forResource: "identity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
            return "Assistant"
        }
        return identity.name
    }()
    private struct Identity: Decodable { let name: String }
}

// Concrete as the material, the system's own controls on top of it, and one plant in the corner.

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
    var onReply: (() -> Void)? = nil
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
                Mark(palette: palette).frame(width: 24, height: 24).padding(.top, 4).help(AssistantIdentity.name)
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
                    if message.reference != nil { Button("Reply") { onReply?() }.buttonStyle(.borderless) }
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
    private var canSend: Bool { chat.connected && !chat.busy && (!chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingImages.isEmpty) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ImageAttachmentPicker(images: $chat.pendingImages, error: $chat.imageError).disabled(chat.busy)
            Button { chat.emailDraftID = nil; chat.showEmailDrafts = true } label: { Image(systemName: "envelope") }
                .buttonStyle(.bordered).controlSize(.large).accessibilityLabel("Email drafts")

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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DaySchedule(payload: chat.calendar, ink: palette.ink, muted: palette.muted, accent: palette.accent)
                Divider()
                DisclosureGroup("Plan notes") {
                    if chat.plans.isEmpty {
                        Text("Nothing planned. Tell me what you’re doing and I’ll keep track.")
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
                }
                HStack(spacing: 6) {
                    Circle().fill(chat.memoryErrors > 0 ? Color.orange : chat.memoryPending > 0 ? palette.accent : palette.muted).frame(width: 6, height: 6)
                    Text(state).font(.caption).foregroundStyle(palette.muted)
                }.padding(.top, 16)
                CornerGrowth(palette: palette, thinking: chat.busy)
                .frame(width: 100, height: 100).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.surface.opacity(0.55))
    }
}

struct ChatConnectionPrompt: View {
    @ObservedObject var chat: Chat
    private var ready: Bool { chat.connectionPromptSatisfied }
    private var provider: String? {
        let value = (chat.connectionPrompt ?? "").replacingOccurrences(of: "_connect", with: "")
        return ServiceSetup.entries[value] == nil ? nil : value
    }
    private var title: String {
        if let provider, let setup = ServiceSetup.entries[provider] { return "Connect " + setup.name }
        let action = chat.connectionPrompt ?? ""
        if let provider = IntegrationCatalog.provider(for: action) {
            return "Connect " + IntegrationCatalog.name(provider, grant: IntegrationCatalog.grant(for: action))
        }
        return "Connection unavailable"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(ready ? "Connected" : title, systemImage: "link").font(.headline)
                Spacer()
                Button { chat.connectionPrompt = nil } label: { Image(systemName: "xmark") }.help("Dismiss connection")
            }
            Text(ready ? "You can pick up where you left off." : "Approve access in your browser, then continue here.").font(.callout).foregroundStyle(.secondary)
            if chat.googleConnecting {
                HStack { ProgressView().controlSize(.small); Text(provider == nil ? "Finish in your browser…" : "Checking connection…") }
            } else if ready {
                Button("Continue") {
                    chat.connectionPrompt = nil
                    chat.draft = "The service is connected now. Please continue my previous request."
                    chat.send()
                }.disabled(chat.busy).buttonStyle(.borderedProminent)
            } else if let provider {
                ServiceConnectionForm(chat: chat, provider: provider)
            } else {
                Button(title) {
                    chat.connectGoogle(chat.connectionPrompt ?? "google_connect")
                }
                    .buttonStyle(.borderedProminent)
            }
            if !chat.connectionError.isEmpty { Text(chat.connectionError).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ServiceSetup {
    let name: String
    let url: String
    let instructions: String
    static let entries = Dictionary(uniqueKeysWithValues: IntegrationCatalog.accounts.map {
        ($0.id, ServiceSetup(name: $0.name, url: $0.setupURL, instructions: $0.instructions))
    })
}

struct ServiceConnectionForm: View {
    @ObservedObject var chat: Chat
    let provider: String
    @State private var token = ""
    var body: some View {
        if chat.serviceConfigured[provider] == false {
            Text("Sign-in for this service has not been configured yet.").font(.callout).foregroundStyle(.secondary)
        } else if IntegrationCatalog.find(provider)?.auth == "oauth" {
            Button("Sign in to \(ServiceSetup.entries[provider]?.name ?? provider)") { chat.connectService(provider) }.buttonStyle(.borderedProminent).disabled(chat.googleConnecting)
        } else if let setup = ServiceSetup.entries[provider] {
            VStack(alignment: .leading, spacing: 8) {
                Text(setup.instructions).font(.callout).foregroundStyle(.secondary)
                Link("Open " + setup.name, destination: URL(string: setup.url)!)
                SecureField("Access token", text: $token).textFieldStyle(.roundedBorder)
                Text("Stored in this Mac’s Keychain. Never sent to the chat.").font(.caption).foregroundStyle(.secondary)
                Button("Connect " + setup.name) {
                    chat.connectService(provider, token: token)
                    token = ""
                }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.googleConnecting)
                    .buttonStyle(.borderedProminent)
            }.onDisappear { token = "" }
        }
    }
}

struct ConnectionsView: View {
    @ObservedObject var chat: Chat
    @State private var serviceSetup: String? = nil
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connections").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cloud.sun").font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weather").font(.headline)
                    Text("Available automatically. No account needed.").font(.callout).foregroundStyle(.secondary)
                    Link("Forecasts by Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(.caption)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar").font(.title2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Google").font(.headline)
                    Text("Read your calendar and recent email to help plan your day.").font(.callout).foregroundStyle(.secondary)
                    if chat.googleConnecting {
                        HStack { ProgressView().controlSize(.small); Text("Finish connecting in your browser…").font(.callout) }
                    } else if chat.googleConnected {
                        Text("Connected").foregroundStyle(.green)
                        if !chat.googleCalendarWrite {
                            Button("Enable calendar editing") { chat.connectGoogle() }.buttonStyle(.borderedProminent)
                        }
                        Button("Disconnect this device") { chat.disconnectGoogle() }
                    } else if chat.googleConfigured {
                        Button("Connect Google") { chat.connectGoogle() }.buttonStyle(.borderedProminent)
                    } else {
                        Text("Google sign-in isn’t available in this build yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("I can add calendar events when you ask. I can read your email, but I can’t send it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(IntegrationCatalog.googleGrants.filter { $0.slot != "google_connect" }) { grant in
                let action = grant.action
                let title = grant.name
                let detail = grant.description
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.headline)
                        Spacer()
                        if chat.googleCapabilities[action] == true {
                            Button("Disconnect") { chat.disconnectGoogle(action) }
                        } else {
                            Button("Connect") { chat.connectGoogle(action) }
                        }
                    }
                    Text(detail + " · Read only").font(.caption).foregroundStyle(.secondary)
                }.disabled(chat.googleConnecting || !chat.googleConfigured)
            }
            Divider()
            ForEach(IntegrationCatalog.accounts.map(\.id), id: \.self) { provider in
                HStack {
                    Text(ServiceSetup.entries[provider]!.name).font(.headline)
                    Spacer()
                    if chat.serviceConnections[provider] == true {
                        Button("Disconnect") { chat.disconnectService(provider) }
                    } else {
                        Button("Connect") { serviceSetup = serviceSetup == provider ? nil : provider }
                    }
                }.disabled(chat.googleConnecting)
                if serviceSetup == provider && chat.serviceConnections[provider] != true {
                    ServiceConnectionForm(chat: chat, provider: provider)
                }
            }
            if !chat.connectionError.isEmpty { Text(chat.connectionError).font(.callout).foregroundStyle(.secondary) }
        }.padding(22).frame(width: 380)
        }.frame(maxHeight: 650).onAppear { chat.refreshConnections() }
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
                Text(AssistantIdentity.name).font(.headline).foregroundStyle(palette.ink)
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
                        if chat.connectionPrompt != nil { ChatConnectionPrompt(chat: chat) }
                        Color.clear.frame(height: 1).id("voice-bottom")
                    }.padding(.horizontal, 18).padding(.bottom, 12)
                }
                .onChange(of: chat.messages.last?.text) { _ in proxy.scrollTo("voice-bottom", anchor: .bottom) }
                .onChange(of: chat.focusedMessage) { if let id = chat.focusedMessage { proxy.scrollTo(id, anchor: .bottom) } }
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
    @State private var showConnections = false
    @State private var showImport = false
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
        .navigationTitle(AssistantIdentity.name)
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
                    Text(chat.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 160).help(chat.status)
                    if !chat.connected && !chat.busy { Button("Reconnect") { chat.connect() }.controlSize(.small) }
                }
                Button { chat.showInbox = true } label: { Image(systemName: "tray") }.help("Inbox")
                    .sheet(isPresented: $chat.showInbox) { MessageInbox(request: chat.inboxRequest, open: chat.openInbox).frame(minWidth: 480, minHeight: 500) }
                Button { showConnections.toggle() } label: { Image(systemName: "link") }
                    .help("Connections")
                    .popover(isPresented: $showConnections) { ConnectionsView(chat: chat) }
                Button { showImport = true } label: { Image(systemName: "tray.and.arrow.down") }
                    .help("Import context")
                    .sheet(isPresented: $chat.showEmailDrafts) { EmailDraftsView(initialID: chat.emailDraftID, request: chat.emailRequest).frame(minWidth: 540, minHeight: 580) }
                    .sheet(isPresented: $showImport) { ContextImportView(upload: chat.importPart, refresh: chat.imports, runtime: chat.runtime) }
                Button("Clear") {
                    chat.draft = ""
                    chat.connect(clear: true)
                }
                .disabled(!chat.connected || chat.busy)
                .help("Start a fresh chat and keep saved memory")
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }.help("Settings")
                    .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover(chat: chat) }
                Button { withAnimation(.easeInOut(duration: 0.2)) { showMemory.toggle() } } label: { Label("Calendar", systemImage: "calendar") }
                    .help(showMemory ? "Hide the day" : "Show the day")
            }
        }
        .toolbarBackground(palette.background, for: .windowToolbar)
        .preferredColorScheme(.light)
        .onAppear {
            chat.liveVoice.prepare()
            if !chat.connected && !chat.busy { chat.connect() }
        }
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
                                Text("I’m \(AssistantIdentity.name). What’s on your mind?").font(.title2).foregroundStyle(palette.ink)
                                Text("I keep what matters, on every device, and pick the thread back up wherever you are.")
                                    .font(.callout).foregroundStyle(palette.muted).frame(maxWidth: 420, alignment: .leading)
                            }.padding(.top, 80)
                        }
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(chat.messages[index - 1].at, inSameDayAs: message.at) {
                                DayMarker(date: message.at, palette: palette)
                            }
                            MessageRow(onReply: { chat.reply(to: message) }, message: message, palette: palette)
                                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(message.id == chat.focusedMessage ? palette.accent : .clear, lineWidth: 1)).id(message.id)
                        MessageImages(ids: message.images, load: chat.imageURL)
                        }
                        if chat.connectionPrompt != nil { ChatConnectionPrompt(chat: chat) }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { followConversation = true }
                            .onDisappear { followConversation = false }
                    }.padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 14)
                        .frame(maxWidth: column).frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.text) { _ in
                    if followConversation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: chat.focusedMessage) { if let id = chat.focusedMessage { proxy.scrollTo(id, anchor: .bottom) } }
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
            PendingImageStrip(images: $chat.pendingImages, error: chat.imageError)
            Composer(chat: chat, palette: palette)
                .frame(maxWidth: column).frame(maxWidth: .infinity)
                .padding(.horizontal, 32).padding(.bottom, 16)
        }
    }
}

@main struct PersonalAssistantApp: App {
    init() { signal(SIGPIPE, SIG_IGN) }
    var body: some Scene {
        WindowGroup { ConversationView() }
    }
}
