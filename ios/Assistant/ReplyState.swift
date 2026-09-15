import Foundation

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String
    var text: String
    var images: [String] = []
    var at: Date = Date()
    var pending = false
    var databaseID: String? = nil
    var reference: [String: String]? = nil
    var inboxSourceID: String? = nil
    var emailDrafts: [String] = []

    static func stored(_ row: [String: Any]) -> ChatMessage? {
        guard let role = row["role"] as? String, let content = row["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let payload = row["payload"] as? [String: Any]
        return ChatMessage(role: role, text: content, images: payload?["images"] as? [String] ?? [], databaseID: row["id"].map { String(describing: $0) }, reference: payload?["reference"] as? [String: String], inboxSourceID: payload?["inbox_source_id"] as? String, emailDrafts: payload?["email_drafts"] as? [String] ?? [])
    }
}

/// Only the current turn can own a pending row or change its reply.
struct ReplyState {
    private(set) var turn: String?
    private(set) var message: UUID?

    mutating func begin(_ turn: String?, messages: inout [ChatMessage]) {
        if let turn, turn == self.turn, message != nil { return }
        finishRows(&messages)
        self.turn = turn
        let row = ChatMessage(role: "assistant", text: "", pending: true)
        message = row.id
        messages.append(row)
    }

    func accepts(_ turn: String?) -> Bool {
        message != nil && (turn == nil || turn == self.turn)
    }

    mutating func update(_ text: String, turn: String?, replace: Bool, messages: inout [ChatMessage]) -> Bool {
        guard accepts(turn), let index = messages.firstIndex(where: { $0.id == message }) else { return false }
        if replace { messages[index].text = text } else { messages[index].text += text }
        return true
    }

    @discardableResult mutating func end(_ turn: String?, messages: inout [ChatMessage]) -> Bool {
        if let turn, turn != self.turn { return false }
        reset(messages: &messages)
        return true
    }

    mutating func reset(messages: inout [ChatMessage]) {
        finishRows(&messages)
        turn = nil; message = nil
    }

    private func finishRows(_ messages: inout [ChatMessage]) {
        messages.removeAll { $0.role == "assistant" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.images.isEmpty && $0.emailDrafts.isEmpty }
        for index in messages.indices { messages[index].pending = false }
    }
}


/// A bounded, device-protected copy for display; the server remains authoritative.
struct ChatCache {
    let account: String
    private let url: URL
    init(account: String, directory: URL? = nil) {
        self.account = account
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Conversation", isDirectory: true)
        url = root.appendingPathComponent((UUID(uuidString: account)?.uuidString ?? "sample") + ".json")
    }
    func read() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url), var rows = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        for index in rows.indices { rows[index].pending = false }
        return rows
    }
    func write(_ messages: [ChatMessage]) {
        let rows = Array(messages.filter { !$0.text.isEmpty || !$0.images.isEmpty || !$0.emailDrafts.isEmpty }.suffix(100))
        guard let data = try? JSONEncoder().encode(rows) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            var destination = url, values = URLResourceValues(); values.isExcludedFromBackup = true
            try destination.setResourceValues(values)
        } catch { /* Reconnection can always restore the server history. */ }
    }
    func clear() { try? FileManager.default.removeItem(at: url) }
}
