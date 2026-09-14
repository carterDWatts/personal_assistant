import Foundation

@main struct MeetingCheck {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(directory: root)
        let id = try library.create(title: "Meeting", runtime: "codex")
        let first = UUID()
        library.update(id, segment: first, offset: 0, text: "The target is four", sealed: false)
        precondition(library.context?.contains("target is four") == true)
        library.checkpoint(queue: true)
        precondition(library.selected!.batches.isEmpty, "Partial recognition must not become durable memory")
        library.update(id, segment: first, offset: 0, text: "The target is fourteen.", sealed: true)
        for i in 1...160 {
            library.update(id, segment: UUID(), offset: Double(i*45), text: "Section \(i). " + String(repeating: "Long conversation 🐇. ", count: 20), sealed: true)
        }
        library.checkpoint(queue: true)
        let doc = library.selected!
        precondition(doc.segments.count == 161 && doc.transcript.contains("fourteen"))
        precondition(doc.batches.allSatisfy { $0.text.unicodeScalars.count <= 12000 })
        precondition(library.context!.unicodeScalars.count < 12000 && library.context!.contains("Section 160"))
        library.update(id, segment: first, offset: 0, text: "Late incorrect callback", sealed: true)
        precondition(!library.selected!.transcript.contains("Late incorrect"))
        let originalIDs = doc.batches.map(\.id)
        library.checkpoint(queue: true)
        precondition(library.selected!.batches.map(\.id) == originalIDs)
        var calls = 0
        library.upload = { _ in calls += 1; throw URLError(.notConnectedToInternet) }
        await library.sync()
        precondition(calls == 1 && library.selected!.batches.allSatisfy { !$0.uploaded })
        let restored = MeetingLibrary(directory: root)
        restored.selectedID = id
        precondition(restored.selected!.ended && restored.selected!.batches.map(\.id) == originalIDs)
        var uploaded: [String] = []
        restored.upload = { args in
            precondition(args["source"] as? String == "meeting")
            uploaded.append(args["id"] as! String)
        }
        await restored.sync(); await restored.sync()
        precondition(uploaded == originalIDs.map(\.uuidString), "Retries must reuse stable IDs and avoid repeating acknowledged uploads")
        restored.useInChat = false
        precondition(restored.context == nil)
        var ordered = MeetingDocument(id: UUID(), title: "Delayed speech", date: Date(), runtime: "codex", kind: "current")
        let old = UUID(), next = UUID()
        ordered.update(id: old, offset: 0, text: "", sealed: false)
        ordered.update(id: next, offset: 45, text: "Second section", sealed: true)
        ordered.queueCompleted()
        precondition(ordered.batches.isEmpty, "A delayed first section must not be skipped")
        ordered.update(id: old, offset: 0, text: "First section", sealed: true)
        ordered.queueCompleted()
        precondition(ordered.transcript.hasPrefix("[0:00] First section"))
        precondition(ordered.batches.count == 1)
        print("Long meetings preserve corrected text, bound live context, and retry durable uploads without duplicates.")
    }
}
