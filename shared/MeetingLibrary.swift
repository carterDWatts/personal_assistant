import Foundation
import Combine

struct MeetingSegment: Codable, Identifiable {
    let id: UUID
    let offset: TimeInterval
    var text: String
    var sealed: Bool
}
struct MeetingBatch: Codable, Identifiable {
    let id: UUID
    let text: String
    var uploaded = false
}
struct MeetingImport: Codable {
    var offset: TimeInterval = 0
    var duration: TimeInterval = 0
    var state = "running"
    var error: String?
}
struct MeetingDocument: Codable, Identifiable {
    let id: UUID
    var title: String
    let date: Date
    let runtime: String
    let kind: String
    var segments: [MeetingSegment] = []
    var batches: [MeetingBatch] = []
    var queuedSegments = 0
    var ended = false
    var audioName: String?
    var processing: MeetingImport?
    var transcript: String {
        segments.filter { !$0.text.isEmpty }.map { "[\(Int($0.offset)/60):\(String(format: "%02d", Int($0.offset)%60))] \($0.text)" }.joined(separator: "\n")
    }
    mutating func update(id: UUID, offset: TimeInterval, text: String, sealed: Bool) {
        if let i = segments.firstIndex(where: { $0.id == id }) {
            guard !segments[i].sealed else { return }
            segments[i].text = text; segments[i].sealed = sealed
        } else { segments.append(MeetingSegment(id: id, offset: offset, text: text, sealed: sealed)) }
    }
    mutating func queueCompleted() {
        let pending = segments.dropFirst(queuedSegments).prefix(while: { $0.sealed })
        guard !pending.isEmpty else { return }
        queuedSegments += pending.count
        let spoken = pending.filter { !$0.text.isEmpty }
        guard !spoken.isEmpty else { return }
        let header = "Meeting: \(title)\nCapture/import time: \(ISO8601DateFormatter().string(from: date))\nAutomatic transcript. Speakers are not identified; do not assume every statement is the user’s.\n"
        let body = spoken.map { "[\(Int($0.offset))s] \($0.text)" }.joined(separator: "\n")
        let scalars = Array(body.unicodeScalars)
        for start in stride(from: 0, to: scalars.count, by: 11000) {
            batches.append(MeetingBatch(id: UUID(), text: header + String(String.UnicodeScalarView(scalars[start..<min(start+11000, scalars.count)]))))
        }
    }
}

/// Local journal and durable, idempotent upload queue. It does not own the chat or a model session.
@MainActor final class MeetingLibrary: ObservableObject {
    @Published private(set) var documents: [MeetingDocument] = []
    @Published var selectedID: UUID?
    @Published var useInChat = false
    @Published var notice = ""
    @Published private(set) var syncing = false
    var upload: (([String: Any]) async throws -> Void)?
    private(set) var directory: URL
    private var generation = UUID()
    private var readable = true
    var selected: MeetingDocument? { documents.first { $0.id == selectedID } }
    var context: String? {
        guard useInChat, let doc = selected, !doc.transcript.isEmpty else { return nil }
        return "Meeting: \(doc.title)\nCapture/import time: \(ISO8601DateFormatter().string(from: doc.date))\nRecent automatic transcript (may contain recognition errors; speakers unidentified):\n" + String(doc.transcript.unicodeScalars.suffix(10000))
    }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PersonalAssistant/Meetings")
        restore()
    }
    func scope(_ name: String) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PersonalAssistant/Meetings/\(name)")
        guard directory != root else { return }
        generation = UUID(); readable = true; directory = root; selectedID = nil; useInChat = false; documents = []; restore()
    }
    private func restore() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) { documents = try JSONDecoder().decode([MeetingDocument].self, from: Data(contentsOf: url)) }
            for i in documents.indices {
                // A terminated app must never silently restart the microphone.
                if documents[i].processing?.state == "running" {
                    documents[i].processing?.state = "paused"
                }
                if documents[i].processing == nil { documents[i].ended = true }
                for j in documents[i].segments.indices { documents[i].segments[j].sealed = true }
                documents[i].queueCompleted()
            }
            selectedID = documents.first(where: { $0.processing != nil && $0.processing?.state != "done" })?.id ?? documents.first?.id
        } catch { readable = false; notice = "Couldn’t read saved recordings. The files have been left in place." }
    }
    @discardableResult func create(title: String, runtime: String, kind: String = "current", date: Date = Date()) throws -> UUID {
        let id = UUID()
        documents.insert(MeetingDocument(id: id, title: String(title.prefix(150)), date: date, runtime: runtime, kind: kind), at: 0)
        selectedID = id; useInChat = true
        try persist()
        return id
    }
    func update(_ id: UUID, segment: UUID, offset: TimeInterval, text: String, sealed: Bool) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].update(id: segment, offset: offset, text: text, sealed: sealed)
    }
    func audio(_ id: UUID, name: String) throws {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].audioName = name; try persist()
    }
    func processing(_ id: UUID, _ progress: MeetingImport) throws {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].processing = progress
        documents[i].ended = progress.state == "done"
        let pendingStart = documents[i].segments.dropFirst(documents[i].queuedSegments).first?.offset ?? progress.offset
        // Checkpoint every section, but batch memory extraction rather than making one model call per phrase.
        if progress.state != "running" || progress.offset - pendingStart >= 90 { documents[i].queueCompleted() }
        try persist()
    }
    func finish(_ id: UUID) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[i].ended = true
        for j in documents[i].segments.indices { documents[i].segments[j].sealed = true }
        checkpoint(queue: true)
    }
    func checkpoint(queue: Bool = false) {
        if queue { for i in documents.indices { documents[i].queueCompleted() } }
        do { try persist() } catch { notice = "Couldn’t save the transcript on this device. Stop recording and check available storage." }
    }
    func persist() throws {
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        let url = directory.appendingPathComponent("library.json")
        let data = try JSONEncoder().encode(documents)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    func sync() async {
        guard !syncing, let upload else { return }
        syncing = true; let token = generation
        defer { syncing = false }
        do {
            try persist() // Never upload an ID that is not recoverable after a crash.
            for doc in documents.reversed() {
                for (index, batch) in doc.batches.enumerated() where !batch.uploaded {
                    guard generation == token else { return }
                    try await upload(["id": batch.id.uuidString, "title": doc.title, "kind": doc.kind, "runtime": doc.runtime,
                                      "source": "meeting", "recording_id": doc.id.uuidString, "recording_index": index,
                                      "part": 0, "parts": 1, "text": batch.text])
                    guard generation == token else { return }
                    if let i = documents.firstIndex(where: { $0.id == doc.id }), let j = documents[i].batches.firstIndex(where: { $0.id == batch.id }) {
                        documents[i].batches[j].uploaded = true; try persist()
                    }
                }
            }
            notice = ""
        } catch { notice = "Transcript saved here. Memory upload will retry when connected." }
    }
}
