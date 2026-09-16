import Foundation
import Combine
import Network

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
    let meetings: MeetingLibrary
    let meetingCapture: MeetingCapture
    private var meetingUpdates: AnyCancellable?
    private let scopeMeetings: Bool
    private var meetingClock: Task<Void, Never>?
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
    func moneyRequest() async throws -> [String: Any] { try await clientRequest("money", [:]) }
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
    private var pendingSubmission: String? = UserDefaults.standard.string(forKey: "pendingSubmission") {
        didSet { UserDefaults.standard.set(pendingSubmission, forKey: "pendingSubmission") }
    }
    @Published var draft: String = {
        let saved = UserDefaults.standard.string(forKey: "draft") ?? ""
        return saved.isEmpty ? UserDefaults.standard.string(forKey: "pendingSubmission") ?? "" : saved
    }() {
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
    @Published private(set) var networkAvailable = true
    @Published private(set) var sendNotice: String?
    private let networkMonitor = NWPathMonitor()
    private var connectionRequested = false
    private var connectionDeadline: Task<Void, Never>?
    private let connectionTimeout: Duration
    var composerNotice: String? {
        if !networkAvailable { return "You’re offline. Your draft is saved on this Mac. I’ll reconnect when you’re back online." }
        if let sendNotice { return sendNotice }
        if !connected { return busy ? "Connecting… You can keep writing while I connect." : "I’m disconnected. Reconnect to send your message. Your draft is saved on this Mac." }
        return nil
    }
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

    init(connection: EngineConnection, monitorNetwork: Bool = true, connectionTimeout: Duration = .seconds(45), meetingLibrary: MeetingLibrary? = nil) {
        scopeMeetings = meetingLibrary == nil
        let library = meetingLibrary ?? MeetingLibrary()
        meetings = library; meetingCapture = MeetingCapture(library: library)
        self.connection = connection
        self.connectionTimeout = connectionTimeout
        connection.onEvent = { [weak self] event in self?.receive(event) }
        connection.onClose = { [weak self] in self?.connectionClosed("Disconnected") }
        voiceSubscription = liveVoice.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        liveVoice.onSpeech = { [weak self] in self?.interruptForSpeech() }
        liveVoice.onUtterance = { [weak self] text in self?.sendVoice(text) }
        liveVoice.onError = { [weak self] text in self?.voice = false; self?.status = text }
        library.upload = { [weak self] args in
            guard let self, self.connected else { throw URLError(.notConnectedToInternet) }
            _ = try await self.clientRequest("meeting_import", args)
        }
        meetingUpdates = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if meetingLibrary == nil { startMeetingClock() }
        if monitorNetwork {
            networkMonitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                Task { @MainActor [weak self] in self?.networkChanged(available: available) }
            }
            networkMonitor.start(queue: DispatchQueue(label: "assistant.network"))
        }
    }

    deinit { networkMonitor.cancel(); connectionDeadline?.cancel(); meetingClock?.cancel() }

    func networkChanged(available: Bool) {
        guard networkAvailable != available else { return }
        networkAvailable = available
        if !available {
            connection.close()
            connectionClosed("Offline")
        } else if connectionRequested { connect() }
    }

    func connect(clear: Bool = false) {
        disconnect()
        connectionRequested = true
        if scopeMeetings { meetings.scope(test ? "mac-test" : "mac-prod") }
        guard networkAvailable else { status = "Offline"; return }
        if clear { messages = [] }
        sendNotice = nil
        connectionPrompt = nil
        notificationReference = nil; focusedMessage = nil
        do {
            try connection.start(test: test)
            busy = true; status = "Connecting…"
            guard write(["type": "connect", "runtime": runtime, "clear": clear]) else { return }
            connectionDeadline = Task { [weak self, connectionTimeout] in
                do { try await Task.sleep(for: connectionTimeout) } catch { return }
                guard let self, !self.connected else { return }
                self.connection.close()
                self.connectionClosed("Connection timed out")
                self.sendNotice = "I couldn’t connect. Check your internet connection, then reconnect. Your draft is still here."
            }
        } catch {
            status = "Could not start the engine"
            sendNotice = "I couldn’t start. Try reopening the app. Your draft is still here."
        }
    }

    func disconnect(immediately: Bool = false) {
        connectionRequested = false
        connection.close(immediately: immediately)
        connectionClosed("Disconnected")
    }

    private func connectionClosed(_ message: String) {
        connectionDeadline?.cancel(); connectionDeadline = nil
        if let pendingSubmission, draft.isEmpty { draft = pendingSubmission }
        if connected && busy { sendNotice = "The connection dropped during your reply. Reconnect to check the conversation before sending again." }
        let pending = clientPending; clientPending.removeAll()
        for waiter in pending.values { waiter.resume(throwing: NSError(domain: "Client", code: 2, userInfo: [NSLocalizedDescriptionKey: "The connection closed. Reconnect and check the request’s status before trying again."])) }
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

    @discardableResult private func write(_ value: [String: Any]) -> Bool {
        do { try connection.send(value); return true }
        catch { connection.close(); connectionClosed("Connection closed"); return false }
    }

    func receive(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let text = event["text"] as? String ?? ""
        switch type {
        case "message_saved":
            if pendingSubmission == text { pendingSubmission = nil }
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
            connectionDeadline?.cancel(); connectionDeadline = nil
            if !connected { sendNotice = nil }
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
        case "error":
            if let pendingSubmission, draft.isEmpty { draft = pendingSubmission }
            connectionDeadline?.cancel(); connectionDeadline = nil
            sendNotice = text; busy = false; status = text; voice = false; liveVoice.stop(); voiceTurn = VoiceTurn(); finishStreaming()
        default: break
        }
    }

    private func finishStreaming() {
        messages.removeAll { $0.id == streamingID && $0.text.isEmpty && $0.images.isEmpty && $0.emailDrafts.isEmpty }
        streamingID = nil
    }

    private func startMeetingClock() {
        meetingClock = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                ticks += 1
                self.meetings.checkpoint(queue: ticks % 9 == 0 || !self.meetingCapture.active)
                await self.meetings.sync()
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard networkAvailable, connected, !busy, !text.isEmpty || !pendingImages.isEmpty else { return }
        sendNotice = nil
        if pendingImages.isEmpty { if submit(text) { draft = "" }; return }
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
                pendingSubmission = content
                guard write(["type": "send", "text": content, "images": ids]) else { return }
                draft = ""
                messages.append(ChatMessage(role: "user", text: content, images: ids))
            } catch { if generation == imageGeneration { imageError = error.localizedDescription; busy = false } }
        }
    }

    @discardableResult private func submit(_ text: String) -> Bool {
        liveVoice.silencePlayback()
        speechBuffer = ""
        var command: [String: Any] = ["type": "send", "text": text]
        if let reference = notificationReference { command["notification"] = reference }
        if let context = meetings.context { command["meeting_context"] = context }
        pendingSubmission = text
        guard write(command) else { return false }
        selectedInboxMessageID = nil
        messages.append(ChatMessage(role: "user", text: text)); busy = true; status = "Thinking…"
        notificationReference = nil
        replyingTo = nil
        return true
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
        endVoice()
        if voiceTurn.interrupt(busy: busy) { write(["type": "stop"]) }
    }

    func endVoice() {
        liveVoice.stop(); speechBuffer = ""; voice = false; voiceTurn.discardPending()
    }

    func toggleVoice() {
        if voice { endVoice(); return }
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
