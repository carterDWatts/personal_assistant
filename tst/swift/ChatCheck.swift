import Foundation
import Darwin

@main struct ChatCheck {
    @MainActor static func wait(_ message: String, until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !ready() {
            guard Date() < deadline else { throw NSError(domain: message, code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("engine"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("engine/__init__.py"))
        // A real pipe/process peer exercises the app protocol without memory, models or audio.
        let fixture = #"""
        import json, os, sys
        def emit(event):
            print(json.dumps(event, ensure_ascii=False), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            kind = request['type']
            if kind in ('quit', 'exit'): break
            if kind == 'burst':
                os.write(1, b'not json\n')
                for i in range(100):
                    data = (json.dumps({'type':'delta','text':f'{i}:hello 🐇'}, ensure_ascii=False)+'\n').encode()
                    split = data.index('🐇'.encode()) + 1
                    os.write(1, data[:split]); os.write(1, data[split:])
                emit({'type':'end'})
                break
            if kind == 'reconnect':
                os.write(1, b'{"type":"reconnect"}\n{"type":"stale"}\n')
            if kind == 'connect':
                emit({**request, 'type':'command'})
                emit({'type':'history','messages':[{'role':'assistant','content':os.environ['ASSISTANT_ENV'],'id':1}]})
                emit({'type':'ready'})
            if kind == 'send':
                emit({**request, 'type':'command'})
                emit({'type':'start'})
                emit({'type':'delta','text':request['text']})
                emit({'type':'end'})
                emit({'type':'ready'})
            if kind == 'inbox':
                emit({'type':'client_response','request_id':request['request_id'],'result':{'messages':[{'id':25,'role':'assistant','content':'A reminder','payload':{'reference':{'kind':'notice','id':'fixture'}}}]}})
            if kind == 'inbox_open':
                emit({'type':'client_response','request_id':request['request_id'],'result':{'message':{'id':26,'role':'assistant','content':'A reminder','payload':{'reference':{'kind':'notice','id':'fixture'},'inbox_source_id':'25'}}}})
            if kind == 'imports':
                if os.environ['ASSISTANT_ENV'] == 'test': emit({'type':'status','text':'import_waiting'})
                else: emit({'type':'imports','request_id':request['request_id'],'imports':[{'state':'processed'}]})
        """#
        try fixture.write(to: root.appendingPathComponent("engine/desktop.py"), atomically: true, encoding: .utf8)
        let settings: [String: Any] = ["AssistantRoot": root.path, "AssistantPython": "/usr/bin/python3"]
        let connection = EngineConnection(settings: settings)
        defer { connection.close(); connection.onEvent = nil; connection.onClose = nil }

        var received: [String] = []
        var endings = 0
        connection.onEvent = { received.append($0["text"] as? String ?? $0["type"] as? String ?? "") }
        connection.onClose = { endings += 1; received.append("closed") }
        try connection.start(test: true)
        try connection.send(["type": "burst"])
        try await wait("engine EOF") { endings == 1 }
        precondition(received == (0..<100).map { "\($0):hello 🐇" } + ["end", "closed"], "Final text must arrive before disconnect")
        do { try connection.send(["type": "send"]); preconditionFailure("Closed pipes must reject writes") }
        catch { }

        received = []
        var restartError: Error?
        connection.onEvent = { event in
            let type = event["type"] as? String ?? ""
            received.append(type)
            if type == "reconnect" {
                do {
                    try connection.start(test: false)
                    try connection.send(["type": "connect"])
                } catch { restartError = error }
            }
        }
        try connection.start(test: true)
        try connection.send(["type": "reconnect"])
        try await wait("replacement engine ready") { received.contains("ready") || restartError != nil }
        if let restartError { throw restartError }
        precondition(!received.contains("stale"), "Old buffered events must not enter a new conversation")
        precondition(endings == 1, "Closing an old engine must not disconnect its replacement")
        connection.close()

        let invalid = EngineConnection(settings: ["AssistantRoot": root.path, "AssistantPython": "/missing/python"])
        do { try invalid.start(test: true); preconditionFailure("Missing executable must fail") }
        catch { invalid.close() }

        let oldTest = UserDefaults.standard.object(forKey: "testMemory")
        let oldDraft = UserDefaults.standard.object(forKey: "draft")
        defer {
            UserDefaults.standard.set(oldTest, forKey: "testMemory")
            UserDefaults.standard.set(oldDraft, forKey: "draft")
        }
        let chat = Chat(connection: connection)
        defer { chat.disconnect() }
        var command: [String: Any] = [:]
        let receive = connection.onEvent
        connection.onEvent = { event in
            if event["type"] as? String == "command" { command = event }
            receive?(event)
        }
        precondition(!chat.liveVoice.isPrepared && !chat.liveVoice.active)
        chat.test = true
        chat.connect()
        try await wait("test chat ready") { chat.connected }
        precondition(chat.messages.first?.text == "test")
        chat.reply(to: ChatMessage(role: "assistant", text: "A reminder", databaseID: "25", reference: ["kind": "notice", "id": "fixture"]))
        try await wait("inbox selected") { chat.messages.last?.databaseID == "26" }
        chat.draft = "Hello 🐇\nAnother paragraph."
        chat.send()
        try await wait("chat reply") { !chat.busy }
        precondition(chat.messages.last?.text == "Hello 🐇\nAnother paragraph.")
        precondition((command["notification"] as? [String: String])?["message_id"] == "25")
        precondition(chat.draft.isEmpty && chat.replyingTo == nil)

        var importCancelled = false
        let pending = Task { @MainActor in
            do { _ = try await chat.imports(); preconditionFailure("The old import cannot complete after reconnect") }
            catch is CancellationError { importCancelled = true }
        }
        try await wait("import pending") { chat.status == "import waiting" }
        chat.reply(to: chat.messages[0])
        chat.test = false
        chat.connect(clear: true)
        try await wait("production chat ready") { chat.connected && importCancelled }
        try await pending.value
        precondition(chat.messages.count == 1 && chat.messages[0].text == "prod")
        precondition(chat.replyingTo == nil)
        precondition(command["clear"] as? Bool == true)
        let imports = try await chat.imports()
        precondition(imports.first?["state"] as? String == "processed")

        chat.receive(["type": "connection_required", "action": "github_connect"])
        chat.receive(["type": "connections", "completed": true, "action": "github_connect"])
        precondition(chat.connectionPrompt == nil)
        let notice: [String: Any] = ["type": "proactive", "message": ["id": 99, "content": "A new update"]]
        chat.receive(notice); chat.receive(notice)
        precondition(chat.messages.filter { $0.databaseID == "99" }.isEmpty)
        chat.receive(["type": "connections", "error": "Sign-in failed", "connecting": false])
        precondition(chat.connectionPrompt == nil)
        chat.receive(["type": "start"])
        chat.receive(["type": "start"])
        precondition(chat.messages.filter { $0.text.isEmpty }.count == 1)
        chat.receive(["type": "end"])
        precondition(!chat.messages.contains { $0.text.isEmpty })
        chat.receive(["type": "start"])
        try connection.send(["type": "exit"])
        try await wait("chat disconnected") { !chat.connected }
        precondition(!chat.busy && !chat.messages.contains { $0.text.isEmpty })
        precondition(!chat.liveVoice.isPrepared && !chat.liveVoice.active, "State tests must not start speech")
        print("Engine framing, final output, reconnect isolation, chat replies, imports and disconnect cleanup passed.")
    }
}
