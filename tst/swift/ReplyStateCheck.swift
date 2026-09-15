import Foundation
@main struct Check {
    static func main() {
        var rows = [ChatMessage(role: "user", text: "Yep, that")]
        var state = ReplyState()
        state.begin("one", messages: &rows)
        precondition(rows.last!.pending)
        state.end("one", messages: &rows)
        precondition(rows.count == 1)
        rows.append(ChatMessage(role: "user", text: "wyd"))
        state.begin("two", messages: &rows)
        state.begin("two", messages: &rows)
        precondition(rows.count == 3)
        precondition(!state.update("Old reply", turn: "one", replace: false, messages: &rows))
        precondition(!state.end("one", messages: &rows))
        precondition(state.update("Listening.", turn: "two", replace: false, messages: &rows))
        state.end("two", messages: &rows)
        precondition(rows.allSatisfy { !$0.pending })
        precondition(rows.last!.text == "Listening.")
        state.begin("three", messages: &rows)
        state.begin("four", messages: &rows)
        precondition(rows.filter(\.pending).count == 1)
        precondition(rows.last!.pending)
        state.reset(messages: &rows)
        precondition(rows.allSatisfy { !$0.pending && !$0.text.isEmpty })
        let stored: [String: Any] = ["id": 123, "role": "assistant", "content": "I found an answer.", "payload": ["reference": ["kind": "notice", "id": "notice-1"]]]
        let notice = ChatMessage.stored(stored)!
        precondition(notice.databaseID == "123" && notice.reference?["id"] == "notice-1")
        state.begin("five", messages: &rows)
        rows.append(notice)
        precondition(state.update("Still answering.", turn: "five", replace: false, messages: &rows))
        precondition(rows.last!.text == "I found an answer.")
        state.end("five", messages: &rows)
        precondition(rows.allSatisfy { !$0.pending })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = UUID().uuidString
        let cache = ChatCache(account: account, directory: directory)
        var cached = notice
        cached.pending = true
        cached.images = ["image-id"]
        cached.emailDrafts = ["draft-id"]
        cache.write([cached])
        let restored = cache.read()
        precondition(restored.count == 1 && restored[0].id == cached.id)
        precondition(restored[0].text == cached.text && restored[0].at == cached.at)
        precondition(restored[0].reference == cached.reference && restored[0].images == cached.images)
        precondition(restored[0].emailDrafts == cached.emailDrafts && !restored[0].pending)
        precondition(ChatCache(account: UUID().uuidString, directory: directory).read().isEmpty)
        cache.write((0..<120).map { ChatMessage(role: "user", text: String($0)) })
        precondition(cache.read().count == 100 && cache.read().first!.text == "20")
        cache.clear()
        precondition(cache.read().isEmpty)
        try! Data("invalid".utf8).write(to: directory.appendingPathComponent(account + ".json"))
        precondition(cache.read().isEmpty)
        print("Finished and superseded turns cannot leave thinking rows.")
    }
}
