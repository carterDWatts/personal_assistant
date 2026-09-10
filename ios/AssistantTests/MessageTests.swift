import XCTest
@testable import Assistant

@MainActor final class MessageTests: XCTestCase {
    func testProactiveMessageDoesNotTakeOverReplyAndCarriesExactReference() async throws {
        let transport = MessageTransport()
        let chat = Chat(transport: transport)
        chat.clearNotificationDiscussion()
        defer { chat.clearNotificationDiscussion(); transport.close() }
        transport.emit(["type":"ready"])
        transport.emit(["type":"start", "turn_id":"turn"])
        transport.emit(["type":"delta", "turn_id":"turn", "text":"Here is your reply."])
        transport.emit(["type":"proactive", "message":transport.row])
        transport.emit(["type":"proactive", "message":transport.row])
        transport.emit(["type":"end", "turn_id":"turn"])
        transport.emit(["type":"ready"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(chat.messages.filter { $0.databaseID == "123" }.count, 1)
        XCTAssertTrue(chat.messages.contains { $0.text == "Here is your reply." })
        XCTAssertFalse(chat.messages.contains { $0.pending })
        XCTAssertFalse(chat.liveVoice.speaking)
        let message = try XCTUnwrap(chat.messages.last)
        chat.reply(to: message)
        chat.draft = "Yes, show me."
        chat.send()
        XCTAssertEqual(transport.reference?["message_id"], "123")
        XCTAssertEqual(transport.reference?["id"], "notice")
        XCTAssertNil(chat.notificationDiscussion)
    }

    func testNotificationOutsideHistoryFetchesAndFocusesItsMessage() async throws {
        let transport = MessageTransport()
        let chat = Chat(transport: transport)
        chat.clearNotificationDiscussion()
        defer { chat.clearNotificationDiscussion(); transport.close() }
        transport.emit(["type":"ready"])
        try await Task.sleep(for: .milliseconds(50))
        chat.discussNotification(kind: "notice", id: "notice", title: "Older message", messageID: "123")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(chat.messages.last?.databaseID, "123")
        XCTAssertEqual(chat.focusedMessage, chat.messages.last?.id)
        XCTAssertEqual(transport.request?["message_id"] as? String, "123")
    }

    func testImageOnlyMessageDoesNotInjectDefaultCaption() async throws {
        let transport = MessageTransport()
        let chat = Chat(transport: transport)
        defer { transport.close() }
        transport.emit(["type":"ready"])
        chat.pendingImages = [try PendingImage(data: Self.jpeg, name: "photo.jpg")]
        chat.send()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(chat.messages.last?.role, "user")
        XCTAssertEqual(chat.messages.last?.text, "")
        XCTAssertEqual(transport.sentImageText, "")
        XCTAssertEqual(transport.sentImages, ["uploaded-image"])
    }

    func testImageMessagePreservesTypedText() async throws {
        let transport = MessageTransport()
        let chat = Chat(transport: transport)
        defer { transport.close() }
        transport.emit(["type":"ready"])
        chat.pendingImages = [try PendingImage(data: Self.jpeg, name: "photo.jpg")]
        chat.draft = "What is this?"
        chat.send()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(chat.messages.last?.text, "What is this?")
        XCTAssertEqual(transport.sentImageText, "What is this?")
    }

    private static let jpeg = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8T9wAAAABJRU5ErkJggg==")!
}

@MainActor private final class MessageTransport: Transport {
    let events: AsyncStream<[String: Any]>
    let emit: ([String: Any]) -> Void
    private let finish: () -> Void
    var reference: [String:String]?
    var request: [String:Any]?
    var sentImageText: String?
    var sentImages: [String]?
    let row: [String:Any] = ["id":123,"role":"assistant","content":"I found something useful.","payload":["reference":["kind":"notice","id":"notice"]]]
    init() {
        let pair = AsyncStream<[String:Any]>.makeStream()
        events = pair.stream
        emit = { pair.continuation.yield($0) }
        finish = { pair.continuation.finish() }
    }
    func connect(clear: Bool) {}
    func send(_ text: String, id: UUID, speech: Bool, model: String?, mode: String, notification: [String:String]?) { reference = notification }
    func sendImages(_ text: String, id: UUID, model: String?, images: [String]) { sentImageText = text; sentImages = images }
    func stop() {}
    func foreground(_ active: Bool) {}
    func close() { finish() }
    func clientRequest(_ action: String, _ args: [String:Any]) async throws -> [String:Any] {
        if action == "image" { return ["id":"uploaded-image"] }
        throw ConnectionFailure("Unavailable in test.")
    }
    func reminderRequest(_ action: String, _ args: [String:Any]) async throws -> [String:Any] { request=args; return ["message":row] }
    func importPart(_ args: [String:Any]) async throws {}
    func imports() async throws -> [[String:Any]] { [] }
    func connections() async throws -> [[String:Any]] { [] }
    func startConnection(provider: String, grant: String?) async throws -> (intent:String,url:URL?) { ("",nil) }
    func connectionState(intent: String) async throws -> (state:String,error:String?) { ("",nil) }
    func connectToken(provider: String, token: String) async throws -> String { "" }
    func removeConnection(provider: String, grant: String?) async throws {}
}
