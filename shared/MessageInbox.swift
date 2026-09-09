import SwiftUI

struct InboxMessage: Identifiable {
    let id: String
    let text: String
    let date: Date
    let opened: Bool
    let row: [String: Any]
    init?(_ row: [String: Any]) {
        guard let id = row["id"], let text = row["content"] as? String else { return nil }
        self.id = String(describing: id); self.text = text; self.row = row
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        date = format.date(from: row["created_at"] as? String ?? "") ?? Date()
        opened = row["opened_at"] is String
    }
}

/// Opening is explicit; merely receiving or browsing messages never adds them to chat.
struct MessageInbox: View {
    let request: ([String: Any]) async throws -> [String: Any]
    let open: ([String: Any], String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [InboxMessage] = []
    @State private var error = ""
    @State private var loading = false
    @State private var opening: String?
    @State private var requests: [String: String] = [:]
    @State private var more = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Inbox").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Messages waiting for you. Open one to talk about it.").font(.subheadline).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        Button {
                            let id = requests[message.id] ?? UUID().uuidString
                            requests[message.id] = id; opening = message.id; error = ""
                            Task {
                                do { try await open(message.row, id); dismiss() }
                                catch { self.error = "I couldn’t open that message. Please try again." }
                                opening = nil
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    if !message.opened { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
                                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if opening == message.id { ProgressView().controlSize(.small) }
                                }
                                Text(message.text).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(opening != nil)
                    }
                    if more { Button("Older messages") { Task { await load(older: true) } }.disabled(loading) }
                    if loading { ProgressView() }
                    if messages.isEmpty && !loading && error.isEmpty { Text("Nothing waiting here.").foregroundStyle(.secondary) }
                }
            }
            Button("Refresh") { Task { await load() } }.disabled(loading || opening != nil)
        }.padding(20).task { await load() }
    }
    private func load(older: Bool = false) async {
        loading = true; defer { loading = false }
        do {
            let result = try await request(older ? ["before_id": messages.last?.id ?? ""] : [:])
            let page = (result["messages"] as? [[String: Any]] ?? []).compactMap(InboxMessage.init)
            messages = older ? messages + page : page; more = page.count == 100; error = ""
        } catch { self.error = "I couldn’t load your inbox. Please try again." }
    }
}
