import Foundation
import Combine

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var images: [String] = []
    var at: Date = Date()
    var databaseID: String? = nil
    var reference: [String: String]? = nil
    var inboxSourceID: String? = nil
    var emailDrafts: [String] = []
}



private let isoFractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlain = ISO8601DateFormatter()

private func parseDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    return isoFractional.date(from: text) ?? isoPlain.date(from: text)
}

private func plain(_ value: Any?) -> String {
    switch value {
    case nil: return ""
    case let s as String: return s
    case let b as Bool: return b ? "yes" : "no"
    case let n as NSNumber: return n.stringValue
    default: return "\(value!)"
    }
}

@MainActor
final class Chat: ObservableObject {
    private var imageGeneration = 0
    @Published var pendingImages: [PendingImage] = []
    @Published var imageError = ""
    func imageRequest(_ args: [String: Any]) async throws -> [String: Any] { try await clientRequest("image", args) }
    func imageURL(_ id: String) async throws -> URL {
        let result = try await imageRequest(["operation": "get", "id": id])
        guard let value = result["url"] as? String, let url = URL(string: value), url.scheme == "https" else { throw ImageError.invalid }
        return url
    }
    @Published var showEmailDrafts = false
    var emailDraftID: String?
    private var clientPending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    func emailRequest(_ args: [String: Any]) async throws -> [String: Any] { try await clientRequest("email", args) }
    func clientRequest(_ action: String, _ args: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            clientPending[id] = continuation
            write(["type": action, "args": args, "request_id": id])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                clientPending.removeValue(forKey: id)?.resume(throwing: NSError(domain: "Client", code: 1, userInfo: [NSLocalizedDescriptionKey: "The request timed out. Check its status before trying again."]))
            }
        }
    }
    @Published var messages: [ChatMessage] = []
    @Published var replyingTo: ChatMessage?
    @Published var selectedInboxMessageID: String?
    func cancelInboxReply() {
        guard let id = selectedInboxMessageID, !busy else { return }
        Task {
            do {
                let result = try await clientRequest("inbox_cancel", ["message_id": id])
                if result["cancelled"] as? Bool == true { messages.removeAll { $0.databaseID == id } }
                selectedInboxMessageID = nil; focusedMessage = nil
                notificationReference = nil; replyingTo = nil
            } catch { status = "I couldn’t cancel that reply. Please try again." }
        }
    }
    @Published var showInbox = false
    @Published var focusedMessage: UUID?
    private var notificationReference: [String: String]?
    func inboxRequest(_ args: [String: Any]) async throws -> [String: Any] { try await clientRequest("inbox", args) }
    func receiveWorkUpdates() async {
        guard connected, !busy else { return }
        if let result = try? await clientRequest("work_updates", [:]) {
            for row in result["messages"] as? [[String: Any]] ?? [] { appendDiscussion(row) }
        }
    }
    func openInbox(_ row: [String: Any], requestID: String) async throws {
        guard connected, !busy, let source = row["id"] else { throw NSError(domain: "Inbox", code: 1) }
        let result = try await clientRequest("inbox_open", ["message_id": String(describing: source), "request_id": requestID])
        guard let selected = result["message"] as? [String: Any] else { throw NSError(domain: "Inbox", code: 1) }
        appendDiscussion(selected)
        selectedInboxMessageID = selected["id"].map { String(describing: $0) }
        notificationReference = (row["payload"] as? [String: Any])?["reference"] as? [String: String]
        notificationReference?["message_id"] = String(describing: source)
        focusedMessage = messages.last?.id
    }
    func reply(to message: ChatMessage) {
        Task {
            do {
                let list = try await inboxRequest([:])
                if let row = (list["messages"] as? [[String: Any]])?.first(where: { String(describing: $0["id"] ?? "") == (message.inboxSourceID ?? message.databaseID) }) {
                    try await openInbox(row, requestID: UUID().uuidString)
                }
            } catch { status = "I couldn’t open that message. Try the inbox." }
        }
    }
    private func appendDiscussion(_ row: [String: Any]) {
        guard let content = row["content"] as? String else { return }
        let id = row["id"].map { String(describing: $0) }
        if !messages.contains(where: { $0.databaseID == id }) {
            messages.append(ChatMessage(role: "assistant", text: content, at: parseDate(row["created_at"]) ?? Date(), databaseID: id, reference: (row["payload"] as? [String: Any])?["reference"] as? [String: String], inboxSourceID: (row["payload"] as? [String: Any])?["inbox_source_id"] as? String, emailDrafts: (row["payload"] as? [String: Any])?["email_drafts"] as? [String] ?? []))
        }
    }
    @Published var draft = UserDefaults.standard.string(forKey: "draft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "draft") }
    }
    @Published var status = "Starting…"
    @Published var memoryStatus = ""
    @Published var googleConfigured = false
    @Published var googleConnected = false
    @Published var googleCalendarWrite = false
    @Published var googleCapabilities: [String: Bool] = [:]
    @Published var serviceConnections: [String: Bool] = [:]
    @Published var serviceConfigured: [String: Bool] = [:]
    @Published var googleConnecting = false
    @Published var connectionError = ""
    @Published var connectionPrompt: String? = nil
    @Published var connectionPromptSatisfied = false
    @Published var plans: [PlanItem] = []
    @Published var calendar: [String: Any] = [:]
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
    private let connection: EngineConnection
    private var speechBuffer = ""
    private var streamingID: UUID?

    convenience init() { self.init(connection: EngineConnection()) }

    init(connection: EngineConnection) {
        self.connection = connection
        connection.onEvent = { [weak self] event in self?.receive(event) }
        connection.onClose = { [weak self] in self?.connectionClosed("Disconnected") }
        voiceSubscription = liveVoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        liveVoice.onSpeech = { [weak self] in self?.interruptForSpeech() }
        liveVoice.onUtterance = { [weak self] text in self?.sendVoice(text) }
        liveVoice.onError = { [weak self] text in self?.voice = false; self?.status = text }
    }

    func connect(clear: Bool = false) {
        disconnect()
        messages = []
        connectionPrompt = nil
        notificationReference = nil; focusedMessage = nil
        do {
            try connection.start(test: test)
            busy = true; status = "Connecting…"
            write(["type": "connect", "runtime": runtime, "clear": clear])
        } catch { status = "Could not start the engine. Rebuild the app." }
    }

    func disconnect() {
        connection.close()
        connectionClosed("Disconnected")
    }

    private func connectionClosed(_ message: String) {
        imageGeneration += 1
        liveVoice.stop(); voice = false; voiceTurn = VoiceTurn()
        finishImport(.failure(CancellationError()))
        finishStreaming()
        replyingTo = nil
        speechBuffer = ""
        memoryStatus = ""
        connected = false; busy = false; googleConnecting = false; status = message
    }

    func connectService(_ provider: String, token: String = "") {
        connectionError = ""; googleConnecting = true
        write(["type": "service_connect", "provider": provider, "token": token.isEmpty ? NSNull() : token as Any])
    }
    func disconnectService(_ provider: String) {
        connectionError = ""; googleConnecting = true
        write(["type": "service_disconnect", "provider": provider])
    }
    func refreshConnections() { write(["type": "connections"]) }
    func connectGoogle(_ action: String = "google_connect") { connectionError = ""; googleConnecting = true; write(["type": action]) }
    func disconnectGoogle(_ action: String = "google_connect") { connectionError = ""; googleConnecting = true; write(["type": "google_disconnect", "connection": action]) }

    private var importRequestID: String?
    private var importWaiter: CheckedContinuation<[[String: Any]], Error>?
    private var importTimeout: Task<Void, Never>?
    func importPart(_ args: [String: Any]) async throws { _ = try await importRequest(["type": "import_part", "args": args]) }
    func imports() async throws -> [[String: Any]] { try await importRequest(["type": "imports"]) }
    private func importRequest(_ args: [String: Any]) async throws -> [[String: Any]] {
        while importWaiter != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        guard connected else { throw NSError(domain: "Import", code: 1) }
        return try await withCheckedThrowingContinuation { continuation in
            importWaiter = continuation
            let id = UUID().uuidString
            importRequestID = id
            var request = args; request["request_id"] = id
            importTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { return }
                if self?.importRequestID == id { self?.finishImport(.failure(NSError(domain: "Import", code: 2))) }
            }
            write(request)
        }
    }

    private func finishImport(_ result: Result<[[String: Any]], Error>) {
        importTimeout?.cancel(); importTimeout = nil
        importRequestID = nil
        let waiter = importWaiter; importWaiter = nil
        waiter?.resume(with: result)
    }

    private func write(_ value: [String: Any]) {
        do { try connection.send(value) }
        catch { connection.close(); connectionClosed("Connection closed") }
    }

    func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let text = event["text"] as? String ?? ""
        switch type {
        case "client_response":
            if let id = event["request_id"] as? String, let pending = clientPending.removeValue(forKey: id) {
                if let error = event["error"] as? String { pending.resume(throwing: NSError(domain: "Client", code: 1, userInfo: [NSLocalizedDescriptionKey: error])) }
                else { pending.resume(returning: event["result"] as? [String: Any] ?? [:]) }
            }
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
            if let id = event["draft_id"] as? String {
                if let index = messages.indices.last, messages[index].role == "assistant" {
                    if !messages[index].emailDrafts.contains(id) { messages[index].emailDrafts.append(id) }
                } else { messages.append(ChatMessage(role: "assistant", text: "", emailDrafts: [id])) }
            }
        case "connection_required":
            connectionPrompt = event["action"] as? String
            connectionPromptSatisfied = false
            refreshConnections()
        case "spotify_control":
            if ["play", "resume"].contains(event["action"] as? String ?? "") {
                liveVoice.stop(); voice = false; speechBuffer = ""; voiceTurn.discardPending()
            }
            status = "Controlling Spotify…"
        case "connections":
            if event["completed"] as? Bool == true {
                let action = event["action"] as? String
                connectionPromptSatisfied = action == connectionPrompt
                if connectionPromptSatisfied { connectionPrompt = nil }
            }
            let capabilities = event["capabilities"] as? [String: [String: Any]] ?? [:]
            let services = event["services"] as? [String: [String: Any]] ?? [:]
            serviceConnections = services.mapValues { $0["connected"] as? Bool ?? false }
            serviceConfigured = services.mapValues { $0["configured"] as? Bool ?? false }
            googleCapabilities = capabilities.mapValues { $0["connected"] as? Bool ?? false }
            googleConfigured = event["configured"] as? Bool ?? false
            googleConnected = event["connected"] as? Bool ?? false
            googleCalendarWrite = event["calendar_write"] as? Bool ?? false
            googleConnecting = event["connecting"] as? Bool ?? false
            connectionError = event["error"] as? String ?? event["message"] as? String ?? ""
            if !connectionError.isEmpty && !googleConnecting { status = connectionError }
        case "history":
            messages = (event["messages"] as? [[String: Any]] ?? []).compactMap { row in
                guard (row["payload"] as? [String: Any])?["proactive"] as? Bool != true, (row["payload"] as? [String: Any])?["inbox_cancelled"] as? Bool != true, let role = row["role"] as? String, let content = row["content"] as? String else { return nil }
                return ChatMessage(role: role, text: content, images: (row["payload"] as? [String: Any])?["images"] as? [String] ?? [], at: parseDate(row["created_at"]) ?? Date(), databaseID: row["id"].map { String(describing: $0) }, reference: (row["payload"] as? [String: Any])?["reference"] as? [String: String], inboxSourceID: (row["payload"] as? [String: Any])?["inbox_source_id"] as? String, emailDrafts: (row["payload"] as? [String: Any])?["email_drafts"] as? [String] ?? [])
            }
        case "proactive": break
        case "inbox_cancelled":
            if let id = event["message_id"] as? String { messages.removeAll { $0.databaseID == id } }
        case "inbox_opened", "work_update":
            if let row = event["message"] as? [String: Any] { appendDiscussion(row) }
        case "ready":
            connected = true; busy = false; status = "Connected"
            if let pending = voiceTurn.ready(), voice { submit(pending) }
        case "start":
            finishStreaming()
            busy = true; speechBuffer = ""; let item = ChatMessage(role: "assistant", text: "")
            streamingID = item.id; messages.append(item); status = "Thinking…"
        case "delta":
            if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text += text }
            if !voiceTurn.interrupted { speechBuffer += text; speakSentences(flush: false); status = "Replying…" }
        case "replace":
            if let i = messages.firstIndex(where: { $0.id == streamingID }) { messages[i].text = text }
        case "end":
            if !voiceTurn.interrupted { speakSentences(flush: true) }
            finishStreaming()
        case "memory": memoryStatus = text
        case "imports":
            if event["request_id"] as? String == importRequestID {
                if event["error"] != nil { finishImport(.failure(NSError(domain: "Import", code: 3))) }
                else { finishImport(.success(event["imports"] as? [[String: Any]] ?? [])) }
            }
        case "map":
            calendar = event["calendar"] as? [String: Any] ?? [:]
            plans = (event["plans"] as? [[String: Any]] ?? []).map(PlanItem.init)
            openQuestions = (event["questions"] as? NSNumber)?.intValue ?? 0
            memoryPending = (event["pending"] as? NSNumber)?.intValue ?? 0
            memoryErrors = (event["errors"] as? NSNumber)?.intValue ?? 0
        case "status": status = text.replacingOccurrences(of: "_", with: " ")
        case "error": busy = false; status = text; voice = false; liveVoice.stop(); voiceTurn = VoiceTurn(); finishStreaming()
        default: break
        }
    }

    private func finishStreaming() {
        messages.removeAll { $0.id == streamingID && $0.text.isEmpty && $0.images.isEmpty && $0.emailDrafts.isEmpty }
        streamingID = nil
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !busy, !text.isEmpty || !pendingImages.isEmpty else { return }
        if pendingImages.isEmpty { draft = ""; submit(text); return }
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
                write(["type": "send", "text": content, "images": ids])
            } catch { if generation == imageGeneration { imageError = error.localizedDescription; busy = false } }
        }
    }

    private func submit(_ text: String) {
        liveVoice.silencePlayback()
        speechBuffer = ""
        selectedInboxMessageID = nil
        messages.append(ChatMessage(role: "user", text: text)); busy = true; status = "Thinking…"
        var command: [String: Any] = ["type": "send", "text": text]
        if let reference = notificationReference { command["notification"] = reference }
        notificationReference = nil
        write(command)
        replyingTo = nil
    }

    func startReview() {
        guard connected, !busy else { return }
        busy = true; status = "Opening review…"
        write(["type": "review"])
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
        imageGeneration += 1
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
