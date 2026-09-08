import Foundation
import Combine
import AuthenticationServices

enum AssistantIdentity {
    static let name: String = {
        guard let url = Bundle.main.url(forResource: "identity", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return "Assistant" }
        return identity.name
    }()
    private struct Identity: Decodable { let name: String }
}

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

/// One conversation, whichever device it is on. Mirrors the Mac client so both read the same events the same way.
@MainActor final class Chat: ObservableObject {
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
    @Published var connectionPrompt: ConnectionPrompt? = nil
    @Published var connections: [Connection] = []
    @Published var tokenForm: String? = nil
    let liveVoice = LiveVoice()
    var spokenDraft: String {
        [voiceTurn.pending, liveVoice.transcript.isEmpty ? nil : liveVoice.transcript].compactMap { $0 }.joined(separator: " ")
    }
    private var voiceTurn = VoiceTurn()
    private var voiceSubscription: AnyCancellable?
    private let transport: Transport
    private var receiving: Task<Void, Never>?
    private var speechBuffer = ""
    private var streamingID: UUID?

    init(transport: Transport? = nil) {
        let transport = transport ?? (ProcessInfo.processInfo.arguments.contains("--sample") ? MockTransport() : RelayTransport())
        self.transport = transport
        voiceSubscription = liveVoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        liveVoice.onSpeech = { [weak self] in self?.interruptForSpeech() }
        liveVoice.onUtterance = { [weak self] text in self?.sendVoice(text) }
        liveVoice.onError = { [weak self] text in self?.voice = false; self?.status = text }
        receiving = Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                self.receive(event)
            }
        }
    }

    func connect(clear: Bool = false) {
        liveVoice.stop(); voice = false; voiceTurn = VoiceTurn()
        messages = []; memoryStatus = ""; streamingID = nil; connectionPrompt = nil
        busy = true; status = "Connecting…"
        transport.connect(clear: clear)
    }

    private func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let text = event["text"] as? String ?? event["message"] as? String ?? ""
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
            busy = true; speechBuffer = ""
            let item = ChatMessage(role: "assistant", text: "")
            streamingID = item.id; messages.append(item); status = "Thinking…"
        case "delta":
            if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text += text }
            if !voiceTurn.interrupted { speechBuffer += text; speakSentences(flush: false); status = "Replying…" }
        case "replace":
            if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text = text }
        case "end":
            if !voiceTurn.interrupted { speakSentences(flush: true) }
            streamingID = nil
        case "connection_required":
            connectionPrompt = ConnectionPrompt(event: event, request: messages.last(where: { $0.role == "user" })?.text)
        case "connections":
            connections = (event["providers"] as? [[String: Any]] ?? []).map(Connection.init)
        case "memory": memoryStatus = text
        case "map":
            plans = (event["plans"] as? [[String: Any]] ?? []).map { PlanItem(item: plain($0["item"]), status: plain($0["status"])) }
            openQuestions = (event["questions"] as? NSNumber)?.intValue ?? 0
            memoryPending = (event["pending"] as? NSNumber)?.intValue ?? 0
            memoryErrors = (event["errors"] as? NSNumber)?.intValue ?? 0
        case "status": status = text.replacingOccurrences(of: "_", with: " ")
        case "error":
            busy = false; status = text; voice = false; liveVoice.stop(); voiceTurn = VoiceTurn()
            if let unsent = event["unsent"] as? String {
                if messages.last?.role == "user" && messages.last?.text == unsent { messages.removeLast() }
                if draft.isEmpty { draft = unsent }
            }
        default: break
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
        transport.send(text, id: UUID())
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
            if voiceTurn.interrupt(busy: busy) { transport.stop() }
        } else {
            submit(text)
        }
    }

    func stop() {
        liveVoice.stop(); speechBuffer = ""; voice = false; voiceTurn.discardPending()
        if voiceTurn.interrupt(busy: busy) { transport.stop() }
        transport.foreground(inFront)
    }

    private var inFront = true

    /// A voice conversation keeps the stream alive with the screen off; otherwise the phone rests in the background.
    func foreground(_ active: Bool) {
        inFront = active
        transport.foreground(active || voice)
    }

    func refreshConnections() {
        Task { if let rows = try? await transport.connections() { connections = rows.map(Connection.init) } }
    }

    /// Connect the service a reply asked for. Google opens the host's authorization sheet; the others take a token.
    func connectService() {
        guard var prompt = connectionPrompt, prompt.phase != .connecting else { return }
        if Service.usesToken(prompt.provider) { tokenForm = prompt.provider; return }
        prompt.phase = .connecting; connectionPrompt = prompt
        Task {
            do {
                try await authorize(provider: prompt.provider, grant: prompt.grant)
                finish(.connected)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                finish(.needed)
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    /// The host's authorization for one grant: open its sheet, then confirm with the host, never from the callback alone.
    func authorize(provider: String, grant: String?) async throws {
        let started = try await transport.startConnection(provider: provider, grant: grant)
        if let url = started.url { _ = try await WebAuth.shared.run(url) }
        var state = try await transport.connectionState(intent: started.intent)
        var waited = 0
        while state.state == "pending" && waited < 30 {
            try await Task.sleep(for: .seconds(1)); waited += 1
            state = try await transport.connectionState(intent: started.intent)
        }
        guard state.state == "connected" else { throw ConnectionFailure(state.error ?? "The connection wasn’t completed.") }
        refreshConnections()
    }

    func submitToken(provider: String, token: String) async -> String? {
        do {
            _ = try await transport.connectToken(provider: provider, token: token)
            tokenForm = nil
            if connectionPrompt?.provider == provider { finish(.connected) }
            refreshConnections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnect(_ provider: String, grant: String? = nil) {
        Task { try? await transport.removeConnection(provider: provider, grant: grant); refreshConnections() }
    }

    /// Ask again what could not be answered before the connection existed.
    func continueRequest() {
        guard let request = connectionPrompt?.request, connected, !busy else { return }
        connectionPrompt = nil
        submit(request)
    }

    private func finish(_ phase: ConnectionPrompt.Phase) {
        guard var prompt = connectionPrompt else { return }
        prompt.phase = phase; connectionPrompt = prompt
        refreshConnections()
    }

    func toggleVoice() {
        if voice { stop(); return }
        voice = true
        transport.foreground(true)
        liveVoice.start()
    }

    func toggleMute() { liveVoice.setMuted(!liveVoice.muted) }

    private func speakSentences(flush: Bool) {
        guard voice else { speechBuffer = ""; return }
        while let chunk = nextSpeechChunk(&speechBuffer, flush: flush) { liveVoice.speak(chunk) }
    }
}

struct ConnectionFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
