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
    let palette: Palette
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
                Mark(palette: palette).frame(width: 26, height: 26)
                Text("Inbox").font(.title2.weight(.semibold)).foregroundStyle(palette.ink)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body).padding(10).background(palette.surface, in: Circle()) }.buttonStyle(.plain).accessibilityLabel("Close inbox")
            }
            Text("A few things I wanted to share.").font(.subheadline).foregroundStyle(palette.muted)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(palette.muted) }
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
                                    if !message.opened { Circle().fill(palette.accent).frame(width: 6, height: 6) }
                                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(palette.muted)
                                    Spacer()
                                    if opening == message.id { ProgressView().controlSize(.small) }
                                }
                                Text(message.text).font(.body).lineSpacing(4).foregroundStyle(palette.ink).multilineTextAlignment(.leading).lineLimit(5)
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.surface.opacity(message.opened ? 0.55 : 1), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.line, lineWidth: 0.7))
                        }.buttonStyle(.plain).disabled(opening != nil)
                    }
                    if more { Button("Older messages") { Task { await load(older: true) } }.disabled(loading) }
                    if loading { ProgressView() }
                    if messages.isEmpty && !loading && error.isEmpty { Text("Nothing waiting here.").foregroundStyle(palette.muted) }
                }
            }
            Button("Refresh") { Task { await load() } }.disabled(loading || opening != nil)
        }.padding(22).background(palette.background.ignoresSafeArea()).tint(palette.accent).task { await load() }
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
