import SwiftUI

struct PlanItem: Identifiable {
    let id: String
    let item, status, day, section: String
    init(item: String, status: String, id: String = UUID().uuidString, day: String = "", section: String? = nil) {
        self.id = id; self.item = item; self.status = status; self.day = day
        self.section = section ?? (["done", "skipped", "dropped"].contains(status) ? "finished" : "current")
    }
    init(_ row: [String: Any]) {
        self.init(item: row["item"] as? String ?? "", status: row["status"] as? String ?? "planned",
                  id: row["id"].map { String(describing: $0) } ?? UUID().uuidString,
                  day: row["day"] as? String ?? "", section: row["section"] as? String)
    }
}

struct PlanNotes: View {
    let plans: [PlanItem]
    let canReview: Bool
    let review: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plan notes").font(.headline)
                Spacer()
                Button("Review together", action: review).font(.caption).disabled(!canReview || plans.isEmpty)
            }
            let current = plans.filter { $0.section == "current" }
            if current.isEmpty {
                Text("No open plans for today.").font(.callout).foregroundStyle(.secondary)
            } else { rows(current) }
            group("Needs review", section: "review")
            group("Coming up", section: "upcoming")
            group("Finished today", section: "finished")
        }
    }
    @ViewBuilder private func group(_ title: String, section: String) -> some View {
        let items = plans.filter { $0.section == section }
        if !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))") { rows(items).padding(.top, 6) }
                .font(.subheadline)
        }
    }
    private func rows(_ items: [PlanItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { plan in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: plan.status == "done" ? "checkmark.circle" : plan.status == "proposed" ? "lightbulb" : "circle")
                        .foregroundStyle(.secondary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plan.item).font(.callout).fixedSize(horizontal: false, vertical: true)
                        if plan.section != "current" || plan.status == "proposed" || plan.status == "partial" {
                            Text([plan.day, plan.status == "proposed" ? "Suggested" : plan.status == "partial" ? "Partly done" : plan.section == "review" ? "Outcome unconfirmed" : plan.status == "planned" ? "" : plan.status.capitalized].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
