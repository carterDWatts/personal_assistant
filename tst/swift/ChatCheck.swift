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
            if kind == 'stop': emit({**request, 'type':'command'})
            if kind == 'send':
                if request['text'] == 'Unacknowledged message': continue
                emit({**request, 'type':'command'})
                emit({'type':'message_saved','text':request['text'],'message_id':2})
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
        let stalled = EngineConnection(settings: settings, heartbeatInterval: .milliseconds(30), heartbeatTimeout: .milliseconds(100))
        var detectedStall = false
        stalled.onClose = { detectedStall = true }
        try stalled.start(test: true)
        try stalled.send(["type": "connect"])
        try await wait("unresponsive engine detected") { detectedStall }
        stalled.close()
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
        let oldPending = UserDefaults.standard.object(forKey: "pendingSubmission")
        defer {
            UserDefaults.standard.set(oldTest, forKey: "testMemory")
            UserDefaults.standard.set(oldDraft, forKey: "draft")
            UserDefaults.standard.set(oldPending, forKey: "pendingSubmission")
        }
        let chat = Chat(connection: connection, monitorNetwork: false, meetingLibrary: MeetingLibrary(directory: root.appendingPathComponent("meetings")))
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

        chat.draft = "Finish this after I leave voice"
        chat.voice = true
        chat.send()
        chat.endVoice()
        precondition(!chat.voice && chat.busy)
        try await wait("reply after voice closes") { !chat.busy }
        precondition(chat.messages.last?.text == "Finish this after I leave voice")
        precondition(command["text"] as? String == "Finish this after I leave voice", "Leaving voice must not send stop")

        for text in ["Second message", "Third message"] {
            chat.draft = text
            chat.send()
            precondition(chat.busy && chat.draft.isEmpty)
            try await wait("next reply") { !chat.busy }
            precondition(chat.messages.last?.text == text)
        }
        chat.draft = "Unacknowledged message"
        chat.send()
        chat.disconnect()
        precondition(chat.draft == "Unacknowledged message", "A lost connection must restore text not yet acknowledged by the database")
        chat.draft = ""
        chat.connect()
        try await wait("reconnect after lost acknowledgement") { chat.connected }

        chat.draft = "Keep this unsent draft 🐇"
        let countBeforeOffline = chat.messages.count
        chat.networkChanged(available: false)
        chat.send()
        precondition(!chat.connected && !chat.busy)
        precondition(chat.composerNotice?.contains("offline") == true)
        precondition(chat.messages.count == countBeforeOffline && chat.draft == "Keep this unsent draft 🐇")
        chat.networkChanged(available: true)
        try await wait("automatic reconnect") { chat.connected }
        precondition(chat.composerNotice == nil && chat.draft == "Keep this unsent draft 🐇")
        precondition(chat.messages.count == 1, "Reconnect must not send the saved draft")

        connection.close() // A stale ready flag must not discard a draft when the pipe rejects send.
        chat.send()
        precondition(!chat.connected && !chat.busy && chat.messages.count == 1)
        precondition(chat.draft == "Keep this unsent draft 🐇" && chat.composerNotice != nil)
        chat.connect()
        try await wait("reconnect after failed write") { chat.connected }

        chat.receive(["type": "error", "text": "The reply failed. Reconnect to continue."])
        chat.receive(["type": "ready"])
        precondition(chat.composerNotice?.contains("reply failed") == true, "Ready must not hide an unsuccessful reply")
        chat.send()
        try await wait("send after recovery") { !chat.busy }
        precondition(chat.draft.isEmpty && chat.composerNotice == nil)

        // Ignore ready to simulate a host that never completes startup.
        let stalledConnection = EngineConnection(settings: settings)
        let timedOut = Chat(connection: stalledConnection, monitorNetwork: false, connectionTimeout: .milliseconds(30), meetingLibrary: MeetingLibrary(directory: root.appendingPathComponent("meetings")))
        stalledConnection.onEvent = nil
        timedOut.connect()
        try await wait("connection timeout") { !timedOut.busy }
        precondition(!timedOut.connected && timedOut.composerNotice?.contains("couldn’t connect") == true)
        timedOut.disconnect()

        chat.disconnect()
        chat.networkChanged(available: false); chat.networkChanged(available: true)
        precondition(!chat.connected && !chat.busy, "Explicit disconnect must not trigger auto-reconnect")
        chat.connect()
        try await wait("reconnect before import checks") { chat.connected }

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
        chat.receive(["type": "connection_required", "action": "notion_connect"])
        chat.receive(["type": "connections", "error": "Sign-in failed", "connecting": false])
        precondition(chat.connectionPrompt == "notion_connect" && chat.connectionError == "Sign-in failed")
        chat.receive(["type": "start"])
        chat.receive(["type": "start"])
        precondition(chat.messages.filter { $0.text.isEmpty }.count == 1)
        chat.receive(["type": "end"])
        precondition(!chat.messages.contains { $0.text.isEmpty })
        chat.receive(["type": "start"])
        try connection.send(["type": "exit"])
        try await wait("chat disconnected") { !chat.connected }
        precondition(!chat.busy && !chat.messages.contains { $0.text.isEmpty })
        chat.receive(["type": "start"])
        chat.receive(["type": "email_draft", "draft_id": "example"])
        chat.receive(["type": "error", "text": "Interrupted"])
        precondition(chat.messages.last?.emailDrafts == ["example"])
        precondition(!chat.showEmailDrafts, "Drafts belong in chat, not an automatic modal")
        precondition(!chat.liveVoice.isPrepared && !chat.liveVoice.active, "State tests must not start speech")
        print("Engine framing, final output, reconnect isolation, chat replies, imports and disconnect cleanup passed.")
    }
}
