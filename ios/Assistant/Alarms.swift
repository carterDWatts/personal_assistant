import AlarmKit
import AppIntents
import SwiftUI

@MainActor protocol AlarmScheduling {
    var supported: Bool { get }
    func authorize() async throws -> Bool
    func current() throws -> Set<UUID>
    func schedule(id: UUID, title: String, at: Date) async throws
    func cancel(id: UUID) throws
}

struct AlarmRequest {
    let id: UUID
    let title: String
    let version: Int
    let at: Date?
    let enabled: Bool
    let receipt: String?
    let receiptVersion: Int?
    init?(_ row: [String: Any]) {
        guard let raw = row["id"] as? String, let id = UUID(uuidString: raw), let version = row["version"] as? Int else { return nil }
        self.id = id; self.version = version
        title = row["title"] as? String ?? "Reminder"
        at = parseDate(row["alarm_at"])
        enabled = row["enabled"] as? Bool == true
        receipt = row["receipt"] as? String
        receiptVersion = row["receipt_version"] as? Int
    }
}

@MainActor final class NativeAlarms: ObservableObject {
    @Published private(set) var statuses: [String: String] = [:]
    @Published var problem = ""
    private let driver: any AlarmScheduling
    private let defaults: UserDefaults
    private var versions: [String: Int]
    init(driver: (any AlarmScheduling)? = nil, defaults: UserDefaults = .standard) {
        if let driver { self.driver = driver }
        else if #available(iOS 26, *) { self.driver = SystemAlarms() }
        else { self.driver = UnsupportedAlarms() }
        self.defaults = defaults
        versions = defaults.dictionary(forKey: "nativeAlarmVersions") as? [String: Int] ?? [:]
    }

    func sync(_ rows: [[String: Any]], now: Date = Date(), receipt: ([String: Any]) async throws -> Void) async throws {
        let requests = rows.compactMap(AlarmRequest.init)
        // Nothing asks for permission just because the app was opened.
        let authorized = requests.contains(where: { $0.enabled }) ? try await driver.authorize() : true
        let current = authorized ? try driver.current() : []
        for request in requests {
            let key = request.id.uuidString.lowercased()
            let status: String
            do {
                if !request.enabled {
                    if current.contains(request.id) { try driver.cancel(id: request.id) }
                    versions.removeValue(forKey: key); status = "cancelled"
                } else if !driver.supported { status = "unsupported" }
                else if !authorized { status = "denied" }
                else if let at = request.at {
                    if versions[key] == request.version && current.contains(request.id) { status = "scheduled" }
                    else if versions[key] == request.version && !current.contains(request.id) { status = "dismissed" }
                    else if request.receiptVersion == request.version && request.receipt == "dismissed" && !current.contains(request.id) { status = "dismissed" }
                    else if at <= now { status = current.contains(request.id) ? "scheduled" : "expired" }
                    else {
                        if current.contains(request.id) { try driver.cancel(id: request.id) }
                        try await driver.schedule(id: request.id, title: request.title, at: at)
                        guard try driver.current().contains(request.id) else { throw AlarmFailure.unconfirmed }
                        versions[key] = request.version; status = "scheduled"
                    }
                } else { status = "failed" }
            } catch { status = "failed" }
            defaults.set(versions, forKey: "nativeAlarmVersions")
            statuses[key] = status
            if request.receipt != status || request.receiptVersion != request.version {
                try await receipt(["id": key, "version": request.version, "status": status])
            }
        }
    }
    func label(_ id: String) -> String {
        switch statuses[id.lowercased()] {
        case "scheduled": "Alarm ready on this iPhone"
        case "denied": "Allow Alarms in iPhone Settings"
        case "unsupported": "Ringing alarms require iOS 26"
        case "failed": "Alarm not scheduled — tap to retry"
        case "expired": "Alarm time passed before it was scheduled"
        case "dismissed": "Alarm dismissed; task remains open"
        case "cancelled": "Alarm cancelled"
        default: "Alarm waiting for this iPhone"
        }
    }
    func applyAction(_ args: [String: Any], title: String) async throws {
        guard let raw = args["id"] as? String, let id = UUID(uuidString: raw), let version = args["version"] as? Int,
              versions[id.uuidString.lowercased()] == version, let action = args["action"] as? String,
              ["done", "cancel", "snooze"].contains(action) else { return }
        var row: [String: Any] = ["id":raw, "version":version + 1, "title":title, "enabled":action == "snooze"]
        if action == "snooze" { row["alarm_at"] = args["until"] }
        // The user's local action takes effect even while its durable server update is queued.
        try await sync([row]) { _ in }
    }
    enum AlarmFailure: Error { case unconfirmed }
}

@MainActor private struct UnsupportedAlarms: AlarmScheduling {
    let supported = false
    func authorize() async throws -> Bool { false }
    func current() throws -> Set<UUID> { [] }
    func schedule(id: UUID, title: String, at: Date) async throws { throw NativeAlarms.AlarmFailure.unconfirmed }
    func cancel(id: UUID) throws {}
}

@available(iOS 26, *) private struct ReminderAlarmMetadata: AlarmMetadata {}

@available(iOS 26, *) @MainActor private struct SystemAlarms: AlarmScheduling {
    let supported = true
    func authorize() async throws -> Bool {
        let manager = AlarmManager.shared
        if manager.authorizationState == .notDetermined { return try await manager.requestAuthorization() == .authorized }
        return manager.authorizationState == .authorized
    }
    func current() throws -> Set<UUID> { Set(try AlarmManager.shared.alarms.map(\.id)) }
    func cancel(id: UUID) throws { try AlarmManager.shared.cancel(id: id) }
    func schedule(id: UUID, title: String, at: Date) async throws {
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: "Open", textColor: .white, systemImageName: "bubble.left"), secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: ReminderAlarmMetadata(), tintColor: .green)
        let configuration = AlarmManager.AlarmConfiguration(schedule: .fixed(at), attributes: attributes,
            secondaryIntent: OpenReminderAlarm(id: id.uuidString, title: title))
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
    }
}

@available(iOS 26, *) struct OpenReminderAlarm: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open reminder"
    static var openAppWhenRun = true
    @Parameter(title: "Reminder") var id: String
    @Parameter(title: "Title") var reminderTitle: String
    init() {}
    init(id: String, title: String) { self.id = id; reminderTitle = title }
    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: id) else { return .result() }
        try? AlarmManager.shared.stop(id: uuid)
        await MainActor.run {
            UserDefaults.standard.set(["kind":"reminder", "id":id, "title":reminderTitle], forKey: "notificationDiscussion")
            Notifications.shared?.onAction?()
        }
        return .result()
    }
}

#if DEBUG
@available(iOS 26, *) struct AlarmCheckView: View {
    @StateObject private var alarms = NativeAlarms()
    @State private var id = UUID()
    @State private var status = "Ready to test"
    var body: some View {
        VStack {
            Text(status)
            Button("Schedule test alarm") {
                Task {
                    defer { try? AlarmManager.shared.cancel(id: id) }
                    do {
                        try await alarms.sync([["id":id.uuidString,"version":1,"title":"Alarm verification",
                            "alarm_at":isoDate(Date().addingTimeInterval(8)),"enabled":true]]) { receipt in
                            status = receipt["status"] as? String ?? "No receipt"
                        }
                        for _ in 0..<25 {
                            if try AlarmManager.shared.alarms.contains(where: { $0.id == id && $0.state == .alerting }) { status = "Alarm is ringing" }
                            try await Task.sleep(for: .seconds(1))
                        }
                    } catch { status = "Alarm test failed" }
                }
            }
            Button("Stop test alarm") { try? AlarmManager.shared.cancel(id: id); status = "Alarm stopped" }
        }
    }
}
#endif
