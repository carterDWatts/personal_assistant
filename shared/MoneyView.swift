import SwiftUI

/// A quiet reference alongside the conversation, using the same bank snapshot.
struct MoneyView: View {
    let palette: Palette
    let load: () async throws -> [String: Any]
    var connect: (() async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [[String: Any]] = []
    @State private var connections: [[String: Any]] = []
    @State private var loading = true
    @State private var error = ""
    @State private var connecting = false
    @State private var connectionError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Mark(palette: palette).frame(width: 26, height: 26)
                Text("Money").font(.title2.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").padding(10) }
                    .buttonStyle(.plain).accessibilityLabel("Close money")
            }
            Text("We can work through the details in our conversation.")
                .font(.subheadline).foregroundStyle(palette.muted)
            if let connect {
                Button {
                    connecting = true; connectionError = ""
                    Task { @MainActor in
                        do { try await connect(); await refresh() }
                        catch { connectionError = error.localizedDescription }
                        connecting = false
                    }
                } label: {
                    HStack {
                        if connecting { ProgressView().controlSize(.small) }
                        Text(connecting ? "Signing in…" : connections.isEmpty ? "Connect a bank" : "Add another bank")
                    }
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(palette.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(connecting).accessibilityLabel("Add bank")
                if !connectionError.isEmpty { Text(connectionError).font(.caption).foregroundStyle(palette.muted) }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
            if !error.isEmpty {
                Text(error).foregroundStyle(palette.muted)
                Button("Try again") { Task { await refresh() } }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !loading && error.isEmpty && connections.isEmpty {
                        Text("Ask me to connect your bank accounts when you’re ready.")
                            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(palette.surface)
                    }
                    ForEach(Array(accounts.enumerated()), id: \.offset) { _, account in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(account["name"] as? String ?? "Account").font(.headline)
                                Spacer()
                                Text(amount(account)).monospacedDigit()
                            }
                            HStack {
                                if let mask = account["mask"] as? String { Text("•• " + mask) }
                                if account["type"] as? String == "credit" { Text("Card balance") }
                                if account["active"] as? Bool == false { Text("No longer reported by bank") }
                            }.font(.caption).foregroundStyle(palette.muted)
                            if let liability = account["liabilities"] as? [String: Any], let due = liability["next_payment_due_date"] as? String {
                                Text("Next payment due " + due).font(.subheadline).foregroundStyle(palette.muted)
                            }
                        }.padding(18).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(Array(connections.enumerated()), id: \.offset) { _, connection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection["institution"] as? String ?? "Bank").font(.caption.weight(.semibold))
                            if connection["last_error"] is String {
                                Text("I couldn’t refresh this connection. These figures may be out of date.")
                            } else if connection["transactions_status"] as? String != "HISTORICAL_UPDATE_COMPLETE" {
                                Text("I’m still gathering the transaction history.")
                            }
                            if let stamp = connection["bank_updated_at"] as? String, let date = parsedDate(stamp) {
                                Text("Bank updated " + date.formatted(date: .abbreviated, time: .shortened))
                            } else { Text("The bank hasn’t supplied an update time.") }
                        }.font(.caption).foregroundStyle(palette.muted)
                    }
                    if !accounts.isEmpty { Text("Balances are bank estimates, not a spending budget.").font(.caption).foregroundStyle(palette.muted) }
                }
            }
        }.padding(24).foregroundStyle(palette.ink).background(palette.background)
        .task { await refresh() }
        #if os(macOS)
        .frame(width: 480, height: 560)
        #endif
    }
    private func parsedDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private func amount(_ account: [String: Any]) -> String {
        guard let value = account["balance"] as? String, let amount = Decimal(string: value) else { return "Unavailable" }
        guard let currency = account["currency"] as? String else { return value }
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? value + " " + currency
    }
    @MainActor private func refresh() async {
        loading = true; error = ""
        do {
            let data = try await load()
            accounts = data["accounts"] as? [[String: Any]] ?? []
            connections = data["connections"] as? [[String: Any]] ?? []
        } catch { self.error = "I couldn’t load your bank summary. Please try again." }
        loading = false
    }
}
