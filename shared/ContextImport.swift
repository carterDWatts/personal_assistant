import SwiftUI

/// The same paste-and-import flow on Mac and phone; transport remains device-specific.
struct ContextImportView: View {
    let upload: ([String: Any]) async throws -> Void
    let refresh: () async throws -> [[String: Any]]
    let runtime: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var kind = "history"
    @State private var importID = UUID()
    @State private var working = false
    @State private var started = false
    @State private var message = ""
    @State private var restored = false
    @State private var records: [[String: Any]] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Give me context").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.disabled(working)
            }
            Text("Paste your notes or a chat history. I’ll preserve the original and work through it in the background.").foregroundStyle(.secondary)
            TextField("A name for this context", text: $title).disabled(started)
            Picker("Source", selection: $kind) {
                Text("Past conversations").tag("history")
                Text("Current notes").tag("current")
            }.disabled(started)
            Text(kind == "history" ? "Old statements won’t replace current facts. I’ll keep uncertain details to check with you." : "These notes describe your situation now. I’ll use them to update memory.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).frame(minHeight: 160, maxHeight: 300).disabled(started)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            HStack {
                Text(message).font(.caption).textSelection(.enabled)
                Spacer()
                Button(working ? "Uploading…" : started ? "Retry upload" : "Import") { Task { await save() } }
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Divider()
            Text("Recent imports").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(records.indices, id: \.self) { index in
                        let item = records[index]
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item["title"] as? String ?? "Context")
                            Text(progress(item)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 130)
        }
        .padding(24)
        #if os(macOS)
        .frame(width: 540)
        #endif
        .onDisappear { try? persist() }
        .interactiveDismissDisabled(working)
        .task {
            if !restored {
                restored = true
                if let data = try? Data(contentsOf: draftURL), let draft = try? JSONDecoder().decode(Draft.self, from: data) {
                    title = draft.title; text = draft.text; kind = draft.kind; importID = draft.id; started = draft.started
                }
            }
            while !Task.isCancelled {
                do { records = try await refresh() }
                catch { if !working { message = "Couldn’t load import progress." } }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func progress(_ item: [String: Any]) -> String {
        let total = item["parts"] as? Int ?? 0, done = item["processed"] as? Int ?? 0
        if (item["errors"] as? Int ?? 0) > 0 { return "\(done) of \(total) parts processed. Waiting to retry." }
        if done == total { return "Processed · original preserved" }
        if item["queued_at"] is NSNull { return "Upload incomplete · retry with the same text" }
        return "\(done) of \(total) parts processed"
    }

    private struct Draft: Codable { let title, text, kind: String; let id: UUID; let started: Bool }
    private var draftURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalAssistant/ContextImport.json")
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Draft(title: title, text: text, kind: kind, id: importID, started: started))
        try data.write(to: draftURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: draftURL.path)
    }

    private func save() async {
        // Unicode scalars bound the Postgres character count without corrupting UTF-8.
        let scalars = Array(text.unicodeScalars)
        guard scalars.count <= 2_400_000, title.count <= 200 else {
            message = "Use a title under 200 characters and split text longer than 2.4 million characters into separate imports."; return
        }
        let parts = stride(from: 0, to: scalars.count, by: 12000).map {
            String(String.UnicodeScalarView(scalars[$0..<min($0 + 12000, scalars.count)]))
        }
        working = true; started = true
        do { try persist() } catch { working = false; started = false; message = "Couldn’t save the upload draft. Try again."; return }
        defer { working = false }
        do {
            for (index, part) in parts.enumerated() {
                try await upload(["id": importID.uuidString, "title": title, "kind": kind, "runtime": runtime,
                                  "part": index, "parts": parts.count, "text": part])
                message = "Uploaded \(index + 1) of \(parts.count) parts"
            }
            records = try await refresh()
            text = ""; title = ""; importID = UUID(); started = false
            try? persist()
            message = "Saved. I’m processing this in the background."
        } catch { message = "Upload interrupted. Retry to continue without duplicating it." }
    }
}
