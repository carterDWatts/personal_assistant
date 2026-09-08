import SwiftUI

struct ScheduleEvent: Identifiable {
    let id: String
    let title: String
    let calendar: String
    let start: Date
    let end: Date
    let allDay: Bool

    static func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: value)
    }

    static func read(_ payload: [String: Any]) -> [Self] {
        (payload["calendars"] as? [[String: Any]] ?? []).flatMap { calendar in
            (calendar["events"] as? [[String: Any]] ?? []).compactMap { event -> Self? in
                guard event["status"] as? String != "cancelled",
                      let start = event["start"] as? [String: Any],
                      let end = event["end"] as? [String: Any],
                      let from = date(start["dateTime"] as? String ?? start["date"] as? String ?? ""),
                      let to = date(end["dateTime"] as? String ?? end["date"] as? String ?? "") else { return nil }
                return Self(id: "\(calendar["calendar_id"] ?? "")/\(event["id"] ?? "")", title: event["summary"] as? String ?? "Untitled event", calendar: calendar["calendar"] as? String ?? "", start: from, end: to, allDay: start["date"] != nil)
            }
        }.sorted { $0.start < $1.start }
    }
}

struct DaySchedule: View {
    let payload: [String: Any]
    let ink: Color
    let muted: Color
    let accent: Color
    @State private var selected = 0
    private var days: [Date] { (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: Date())) } }
    private var day: Date { days[selected] }
    private var events: [ScheduleEvent] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        return ScheduleEvent.read(payload).filter { $0.start < end && $0.end > day }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(day.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
                Spacer()
                if selected != 0 { Button("Today") { selected = 0 }.font(.caption) }
            }
            HStack(spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, date in
                    Button { selected = index } label: {
                        VStack(spacing: 8) {
                            Text(date.formatted(.dateTime.weekday(.narrow))).font(.caption)
                            Text(date.formatted(.dateTime.day())).font(.body.weight(.medium))
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(index == selected ? Color.white : ink)
                            .background(index == selected ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(index == selected ? [.isSelected] : [])
                }
            }
            Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.headline)
            if payload.isEmpty {
                Text("Your calendar will appear here once Google is connected and refreshed.").foregroundStyle(muted).font(.callout)
            } else {
                if let error = payload["error"] as? String { Text(error).font(.caption).foregroundStyle(muted) }
                if events.isEmpty { Text("No events in this calendar view.").font(.callout).foregroundStyle(muted).padding(.vertical, 12) }
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(event.allDay ? "All day" : max(event.start, day).formatted(date: .omitted, time: .shortened))
                            if !event.allDay { Text(event.end.formatted(date: .omitted, time: .shortened)).foregroundStyle(muted) }
                        }.font(.caption).frame(width: 62, alignment: .trailing)
                        Rectangle().fill(accent.opacity(0.6)).frame(width: 3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            Text(event.calendar).font(.caption).foregroundStyle(muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 10).padding(.horizontal, 8)
                        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                if (payload["calendars"] as? [[String: Any]] ?? []).contains(where: { $0["more_available"] as? Bool == true }) {
                    Text("Some events aren’t shown. Ask me for the full schedule.").font(.caption).foregroundStyle(muted)
                }
                if let stamp = payload["fetched_at"] as? String, let date = ScheduleEvent.date(stamp) {
                    Text("Google Calendar · updated \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(muted)
                }
            }
        }.foregroundStyle(ink).tint(accent)
    }
}
