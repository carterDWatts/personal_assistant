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
    @Published var attention: [AttentionItem] = []
    @Published var notificationDiscussion: [String: String]? = UserDefaults.standard.dictionary(forKey: "notificationDiscussion") as? [String: String]
    @Published var focusedMessage: UUID?
    func discussNotification(kind: String, id: String, title: String, messageID: String? = nil) {
        notificationDiscussion = ["kind":kind,"id":id,"title":title]
        if let messageID { notificationDiscussion?["message_id"] = messageID }
        UserDefaults.standard.set(notificationDiscussion, forKey: "notificationDiscussion")
        showNotificationMessage()
    }
    func clearNotificationDiscussion() {
        notificationDiscussion = nil
        UserDefaults.standard.removeObject(forKey: "notificationDiscussion")
    }
    func loadNotificationDiscussion() {
        notificationDiscussion = UserDefaults.standard.dictionary(forKey: "notificationDiscussion") as? [String: String]
        showNotificationMessage()
    }
    func reply(to message: ChatMessage) {
        guard let reference = message.reference, let kind = reference["kind"], let id = reference["id"] else { return }
        discussNotification(kind: kind, id: id, title: message.text, messageID: message.databaseID)
    }
    private func showNotificationMessage() {
        guard let selection = notificationDiscussion else { return }
        let reference = ["kind":selection["kind"] ?? "", "id":selection["id"] ?? ""]
        var request = reference
        if let mid = selection["message_id"] { request["message_id"] = mid }
        if let existing = messages.last(where: { $0.reference == reference && (selection["message_id"] == nil || $0.databaseID == selection["message_id"]) }) { focusedMessage = existing.id; return }
        guard connected else { return }
        Task {
            let result = try? await transport.reminderRequest("notification_message", request)
            guard notificationDiscussion?["id"] == selection["id"] else { return }
            if let row = result?["message"] as? [String: Any] {
                appendProactive(row)
            } else if let title = selection["title"], !title.isEmpty {
                // Older notifications predate persisted outbound messages.
                messages.append(ChatMessage(role: "assistant", text: title, reference: reference))
            }
            focusedMessage = messages.last(where: { $0.reference == reference && (selection["message_id"] == nil || $0.databaseID == selection["message_id"]) })?.id
        }
    }
    private func appendProactive(_ row: [String: Any]) {
        guard var message = ChatMessage.stored(row) else { return }
        if let id = message.databaseID, messages.contains(where: { $0.databaseID == id }) { return }
        message.at = parseDate(row["created_at"]) ?? Date()
        messages.append(message)
    }
    @Published var reminders: [ReminderItem] = []
    @Published var reminderStatus = ""
    @Published var plans: [PlanItem] = []
    @Published var calendar: [String: Any] = [:]
    @Published var openQuestions = 0
    @Published var memoryPending = 0
    @Published var memoryErrors = 0
    @Published var busy = false
    @Published var connected = false
    @Published var voice = false
    private var imageGeneration = 0
    @Published var pendingImages: [PendingImage] = []
    @Published var imageError = ""
    func imageRequest(_ args: [String: Any]) async throws -> [String: Any] { try await transport.clientRequest("image", args) }
    func imageURL(_ id: String) async throws -> URL {
        let result = try await imageRequest(["operation": "get", "id": id])
        guard let value = result["url"] as? String, let url = URL(string: value), url.scheme == "https" else { throw ImageError.invalid }
        return url
    }
    @Published var showEmailDrafts = false
    var emailDraftID: String?
    func emailRequest(_ args: [String: Any]) async throws -> [String: Any] { try await transport.clientRequest("email", args) }
    @Published var connectionPrompt: ConnectionPrompt? = nil
    @Published var connections: [Connection] = []
    @Published var connectionError = ""
    @Published var tokenForm: String? = nil
    @Published private(set) var hostSpeaks = false
    @Published var models: [ModelChoice] = []
    @Published var hostVoices: [ModelChoice] = []
    @Published var selectedModel = UserDefaults.standard.string(forKey: "assistantModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "assistantModel") }
    }
    private var spokenTurns: Set<String> = []
    private var playedChunks: Set<String> = []
    let liveVoice = LiveVoice()
    /// Words captured while a reply was still being interrupted; the voice bar joins them with the live transcript.
    var pendingSpeech: String? { voiceTurn.pending }
    private var voiceTurn = VoiceTurn()
    private var registeredPush: String?
    private var flushingReminders = false
    func registerPush(_ token: String) {
        guard connected, registeredPush != token else { return }
        Task {
            do {
                #if DEBUG
                let environment = "sandbox"
                #else
                let environment = "production"
                #endif
                _ = try await transport.reminderRequest("push_register", ["token":token,"environment":environment])
                registeredPush = token
            } catch { reminderStatus = "Notification connection needs a retry." }
        }
    }
    func reminderAction(_ item: ReminderItem, action: String) {
        var pending = UserDefaults.standard.array(forKey: "reminderActions") as? [[String: Any]] ?? []
        var args: [String: Any] = ["id":item.id,"version":item.version,"action":action,"request_id":UUID().uuidString]
        if action == "snooze" { args["until"] = isoDate(Date().addingTimeInterval(3600)) }
        pending.append(args); UserDefaults.standard.set(pending, forKey: "reminderActions")
        flushReminderActions()
    }
    private func removeReminderAction(_ args: [String: Any]) {
        var latest = UserDefaults.standard.array(forKey: "reminderActions") as? [[String: Any]] ?? []
        if let index = latest.firstIndex(where: {
            if let id = args["request_id"] as? String { return $0["request_id"] as? String == id }
            return $0["id"] as? String == args["id"] as? String && $0["version"] as? Int == args["version"] as? Int && $0["action"] as? String == args["action"] as? String
        }) { latest.remove(at: index) }
        UserDefaults.standard.set(latest, forKey: "reminderActions")
    }
    func flushReminderActions() {
        guard connected, !flushingReminders else { return }
        flushingReminders = true
        Task {
            defer { flushingReminders = false }
            while let pending = UserDefaults.standard.array(forKey: "reminderActions") as? [[String: Any]], let args = pending.first {
                do {
                    let result = try await transport.reminderRequest("reminder_action", args)
                    reminders = (result["reminders"] as? [[String: Any]] ?? []).map(ReminderItem.init)
                    removeReminderAction(args)
                    reminderStatus = ""
                } catch let error as RelayError where error.code == "idempotency_conflict" {
                    removeReminderAction(args)
                    reminderStatus = "That reminder changed. Check it before updating it."
                } catch { reminderStatus = "Update saved on this phone; waiting to sync."; return }
            }
        }
    }
    func importPart(_ args: [String: Any]) async throws { try await transport.importPart(args) }
    func imports() async throws -> [[String: Any]] { try await transport.imports() }
    private let transport: Transport
    private var receiving: Task<Void, Never>?
    private var speechBuffer = ""
    private var replyState = ReplyState()

    init(transport: Transport? = nil) {
        let transport = transport ?? (ProcessInfo.processInfo.arguments.contains("--sample") ? MockTransport() : RelayTransport())
        self.transport = transport
        Notifications.shared?.onToken = { [weak self] token in self?.registerPush(token) }
        Notifications.shared?.onAction = { [weak self] in self?.loadNotificationDiscussion(); self?.flushReminderActions() }
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
        imageGeneration += 1
        if clear { clearNotificationDiscussion() }
        liveVoice.stop(); voice = false; voiceTurn = VoiceTurn()
        messages = []; memoryStatus = ""; replyState.reset(messages: &messages); connectionPrompt = nil
        busy = true; status = "Connecting…"
        transport.connect(clear: clear)
    }

    private func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let turn = event["turn_id"] as? String
        let text = event["text"] as? String ?? event["message"] as? String ?? ""
        switch type {
        case "images_saved":
            let ids = event["images"] as? [String] ?? []
            pendingImages.removeAll { ids.contains($0.id.uuidString.lowercased()) }
        case "image":
            if let image = event["image"] as? [String: Any], let id = image["id"] as? String {
                if let index = messages.indices.last, messages[index].role == "assistant" {
                    if !messages[index].images.contains(id) { messages[index].images.append(id) }
                } else { messages.append(ChatMessage(role: "assistant", text: event["caption"] as? String ?? "", images: [id])) }
            }
        case "email_draft":
            emailDraftID = event["draft_id"] as? String; showEmailDrafts = true
        case "history":
            replyState.reset(messages: &messages)
            liveVoice.silencePlayback(); spokenTurns.removeAll(); playedChunks.removeAll()
            messages = (event["messages"] as? [[String: Any]] ?? []).compactMap { row in
                guard var message = ChatMessage.stored(row) else { return nil }
                message.at = parseDate(row["created_at"]) ?? Date()
                return message
            }
        case "proactive":
            if let row = event["message"] as? [String: Any] { appendProactive(row) }
        case "ready":
            Task { @MainActor in
                await Task.yield()
                if let token = UserDefaults.standard.string(forKey: "pushToken") { registerPush(token) }
                loadNotificationDiscussion()
                flushReminderActions()
            }
            connected = true; busy = false; status = "Connected"
            if let pending = voiceTurn.ready(), voice { submit(pending) }
        case "start":
            busy = true; speechBuffer = ""
            replyState.begin(turn, messages: &messages); status = "Thinking…"
        case "capabilities":
            hostSpeaks = event["speech"] as? Bool == true
            models = (event["models"] as? [[String: Any]] ?? []).compactMap(ModelChoice.init)
            hostVoices = (event["voices"] as? [[String: Any]] ?? []).compactMap(ModelChoice.init)
            if !models.contains(where: { $0.id == selectedModel }) { selectedModel = "" }
        case "delta":
            guard replyState.update(text, turn: turn, replace: false, messages: &messages) else { return }
            if hostSpeaks { status = "Replying…" }
            else if !voiceTurn.interrupted { speechBuffer += text; speakSentences(flush: false); status = "Replying…" }
        case "submitted":
            // Only turns this phone sent from voice mode are ever spoken aloud.
            if event["speech"] as? Bool == true, let turn = event["turn_id"] as? String { spokenTurns.insert(turn) }
        case "speech":
            guard voice, !voiceTurn.interrupted, let turn = event["turn_id"] as? String, spokenTurns.contains(turn),
                  let link = event["url"] as? String, let url = URL(string: link) else { break }
            let key = turn + "/" + plain(event["seq"])
            if playedChunks.insert(key).inserted { liveVoice.play(url, text: text) }
        case "speech_end":
            if let turn = event["turn_id"] as? String, spokenTurns.remove(turn) != nil { liveVoice.finishReplyAudio() }
            if event["status"] as? String == "error" { status = "Speech didn’t come through; the text is here." }
        case "replace":
            _ = replyState.update(text, turn: turn, replace: true, messages: &messages)
        case "end":
            guard replyState.end(turn, messages: &messages) else { return }
            if !hostSpeaks && !voiceTurn.interrupted { speakSentences(flush: true); liveVoice.finishReplyAudio() }
        case "connection_required":
            connectionPrompt = ConnectionPrompt(event: event)
        case "spotify_control":
            if ["play", "resume"].contains(event["action"] as? String ?? "") {
                liveVoice.stop(); voice = false; speechBuffer = ""; voiceTurn.discardPending()
            }
            status = "Controlling Spotify…"
        case "connections":
            connections = (event["providers"] as? [[String: Any]] ?? []).map(Connection.init)
        case "memory": memoryStatus = text
        case "map":
            attention = (event["attention"] as? [[String: Any]] ?? []).map(AttentionItem.init)
            reminders = (event["reminders"] as? [[String: Any]] ?? []).map(ReminderItem.init)
            calendar = event["calendar"] as? [String: Any] ?? [:]
            plans = (event["plans"] as? [[String: Any]] ?? []).map { PlanItem(item: plain($0["item"]), status: plain($0["status"])) }
            openQuestions = (event["questions"] as? NSNumber)?.intValue ?? 0
            memoryPending = (event["pending"] as? NSNumber)?.intValue ?? 0
            memoryErrors = (event["errors"] as? NSNumber)?.intValue ?? 0
        case "status": status = text.replacingOccurrences(of: "_", with: " ")
        case "error":
            guard turn == nil || replyState.accepts(turn) else { return }
            replyState.end(turn, messages: &messages)
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
        guard connected, !busy, !text.isEmpty || !pendingImages.isEmpty else { return }
        if pendingImages.isEmpty { draft = ""; submit(text, speak: false); return }
        let photos = pendingImages
        let generation = imageGeneration
        busy = true; imageError = ""; status = "Uploading images…"
        Task {
            do {
                var ids: [String] = []
                for image in photos {
                    let result = try await imageRequest(image.upload)
                    guard let id = result["id"] as? String else { throw ImageError.invalid }
                    ids.append(id)
                }
                guard connected, generation == imageGeneration else { throw ImageError.invalid }
                let content = text.isEmpty ? "Please look at these images." : text
                draft = ""
                messages.append(ChatMessage(role: "user", text: content, images: ids))
                transport.sendImages(content, id: UUID(), model: selectedModel.isEmpty ? nil : selectedModel, images: ids)
            } catch { if generation == imageGeneration { imageError = error.localizedDescription; busy = false } }
        }
    }

    private func submit(_ text: String, speak: Bool = true, mode: String = "talk") {
        replyState.reset(messages: &messages)
        liveVoice.silencePlayback()
        spokenTurns.removeAll(); playedChunks.removeAll()
        speechBuffer = ""
        if speak && voice { liveVoice.prepareReply() }
        messages.append(ChatMessage(role: "user", text: text)); busy = true
        transport.send(text, id: UUID(), speech: speak && voice && hostSpeaks, model: selectedModel.isEmpty ? nil : selectedModel, mode: mode, notification: notificationDiscussion.map { $0.filter { ["kind", "id", "message_id"].contains($0.key) } })
        clearNotificationDiscussion()
    }

    func startMorning() {
        guard connected, !busy else { return }
        submit("Let’s plan my day.", mode: "morning")
    }

    private func interruptForSpeech() {
        guard !liveVoice.muted else { return }
        liveVoice.silencePlayback(); liveVoice.userBeganSpeaking(); speechBuffer = ""
        spokenTurns.removeAll(); playedChunks.removeAll()
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
        imageGeneration += 1
        liveVoice.stop(); speechBuffer = ""; voice = false; voiceTurn.discardPending()
        if voiceTurn.interrupt(busy: busy) || hostSpeaks { transport.stop() }
        transport.foreground(inFront)
    }

    private var inFront = true

    /// A voice conversation keeps the stream alive with the screen off; otherwise the phone rests in the background.
    func foreground(_ active: Bool) {
        inFront = active
        transport.foreground(active || voice)
    }

    func refreshConnections() {
        Task {
            do { connections = try await transport.connections().map(Connection.init); connectionError = "" }
            catch { connectionError = error.localizedDescription }
        }
    }

    /// Connect through the method declared by the integration catalog.
    func connectService() {
        guard var prompt = connectionPrompt, prompt.phase != .connecting else { return }
        guard IntegrationCatalog.find(prompt.provider) != nil else { finish(.failed("This service does not have an integration yet.")); return }
        if connections.first(where: { $0.id == prompt.provider })?.configured == false {
            finish(.failed("Sign-in for this service has not been configured yet.")); return
        }
        if Service.usesToken(prompt.provider) { tokenForm = prompt.provider; return }
        prompt.phase = .connecting; connectionPrompt = prompt
        Task {
            do {
                try await authorize(provider: prompt.provider, grant: prompt.grant)
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
        while ["pending", "processing"].contains(state.state) && waited < 30 {
            try await Task.sleep(for: .seconds(1)); waited += 1
            state = try await transport.connectionState(intent: started.intent)
        }
        guard state.state == "connected" else { throw ConnectionFailure(state.error ?? "The connection wasn’t completed.") }
        if let prompt = connectionPrompt, prompt.provider == provider,
           prompt.grant == grant || (grant == "calendar_write" && prompt.grant == "calendar") {
            connectionPrompt = nil
        }
        refreshConnections()
    }

    func submitToken(provider: String, token: String) async -> String? {
        do {
            _ = try await transport.connectToken(provider: provider, token: token)
            tokenForm = nil
            if connectionPrompt?.provider == provider { connectionPrompt = nil }
            refreshConnections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnect(_ provider: String, grant: String? = nil) {
        Task { try? await transport.removeConnection(provider: provider, grant: grant); refreshConnections() }
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

struct ModelChoice: Identifiable {
    let id: String
    let name: String
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
        self.id = id; self.name = name
    }
}

struct AttentionItem: Identifiable {
    let id, title, detail: String
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        title = row["title"] as? String ?? ""
        detail = row["detail"] as? String ?? ""
    }
}
