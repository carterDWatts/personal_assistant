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
        print("Finished and superseded turns cannot leave thinking rows.")
    }
}
