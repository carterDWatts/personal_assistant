import SwiftUI

struct EmailDraft: Identifiable {
    let row: [String: Any]
    var id: String { row["id"] as? String ?? "" }
    var state: String { row["state"] as? String ?? "draft" }
    var payload: [String: Any] { row["payload"] as? [String: Any] ?? [:] }
    var subject: String { payload["subject"] as? String ?? "Untitled email" }
    var body: String { payload["body"] as? String ?? "" }
    var approval: [String: Any] { ["id": id, "version": row["version"] ?? 0, "content_hash": row["content_hash"] ?? ""] }
    func field(_ key: String) -> String { (payload[key] as? [String])?.joined(separator: ", ") ?? payload[key] as? String ?? "" }
}

/// A draft belongs to the reply that created it. Sending still requires the reviewed version.
struct EmailDraftPreview: View {
    let id: String
    let request: ([String: Any]) async throws -> [String: Any]
    let review: () -> Void
    @State private var draft: EmailDraft?
    var body: some View {
        Button(action: review) {
            VStack(alignment: .leading, spacing: 8) {
                Label(draft?.subject ?? "Email draft", systemImage: "envelope")
                    .font(.headline).foregroundStyle(.primary)
                if let draft {
                    Text("To: " + draft.field("to")).font(.caption).foregroundStyle(.secondary)
                    Text(draft.body).font(.callout).lineLimit(4).foregroundStyle(.primary)
                }
                Text("Review email").font(.callout.weight(.medium))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1)))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).accessibilityIdentifier("email-draft-" + id)
            .task(id: id) { if let row = try? await request(["operation": "get", "id": id]) { draft = EmailDraft(row: row) } }
    }
}

struct EmailDraftsView: View {
    var initialID: String? = nil
    let request: ([String: Any]) async throws -> [String: Any]
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [EmailDraft] = []
    @State private var selected: String?
    @State private var reviewed: EmailDraft?
    @State private var changed = false
    @State private var working = false
    @State private var error = ""
    private var current: EmailDraft? { reviewed?.id == selected ? reviewed : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let draft = current {
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(draft.subject).font(.title2.weight(.semibold))
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(["from", "to", "cc", "bcc"], id: \.self) { key in
                                        if !draft.field(key).isEmpty {
                                            HStack(alignment: .top) {
                                                Text(key.capitalized).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                                                Text(draft.field(key)).textSelection(.enabled)
                                            }.font(.callout)
                                        }
                                    }
                                }
                                Divider()
                                Text(draft.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).lineSpacing(5)
                            }.padding(24)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red) }
                            if let detail = draft.row["error"] as? String { Text(detail).font(.callout).foregroundStyle(.secondary) }
                            if changed {
                                Button("Review updated draft") {
                                    reviewed = drafts.first { $0.id == selected }; changed = false; error = ""
                                }
                            }
                            HStack {
                                Text(label(draft.state)).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                if draft.state == "draft" {
                                    Button("Discard", role: .destructive) { Task { await act("discard", draft) } }.disabled(working)
                                    Button("Send email") { Task { await act("approve", draft) } }
                                        .buttonStyle(.borderedProminent).disabled(working || changed)
                                }
                            }
                        }.padding(20)
                    }
                } else {
                    List(drafts) { draft in
                        Button { selected = draft.id; reviewed = draft; changed = false; error = "" } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.subject).foregroundStyle(.primary)
                                Text(draft.field("to")).font(.caption).foregroundStyle(.secondary)
                                Text(label(draft.state)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }.overlay { if drafts.isEmpty { Text(error.isEmpty ? "No email drafts yet. Ask me to write one." : error).foregroundStyle(.secondary).padding() } }
                }
            }
            .navigationTitle("Review email")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                selected = initialID
                while !Task.isCancelled {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
        }
    }

    private func label(_ state: String) -> String {
        switch state {
        case "draft": return "Review before sending."
        case "queued", "sending": return "Sending…"
        case "sent": return "Sent through Gmail."
        case "uncertain": return "Delivery unconfirmed. Check Gmail Sent."
        case "failed": return "Not sent. Prepare a new draft."
        default: return state.capitalized
        }
    }
    private func refresh() async {
        do {
            if let selected { drafts = [EmailDraft(row: try await request(["operation": "get", "id": selected]))] }
            else { drafts = (try await request(["operation": "list"])["drafts"] as? [[String: Any]] ?? []).map { EmailDraft(row: $0) } }
            if let latest = drafts.first(where: { $0.id == selected }) {
                if let reviewed, reviewed.id == selected, reviewed.row["content_hash"] as? String != latest.row["content_hash"] as? String {
                    changed = true; error = "This draft changed. Review the update before sending."
                } else { reviewed = latest }
            }
        }
        catch { self.error = error.localizedDescription }
    }
    private func act(_ operation: String, _ draft: EmailDraft) async {
        guard !working else { return }
        working = true; error = ""
        defer { working = false }
        do {
            _ = try await request(draft.approval.merging(["operation": operation]) { _, new in new })
            if operation == "discard" { selected = nil }
        } catch { self.error = "The draft could not be confirmed. Review the current version before trying again." }
        await refresh()
    }
}
