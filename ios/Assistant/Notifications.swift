import UIKit
import UserNotifications

@MainActor final class Notifications: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var shared: Notifications!
    override init() { super.init(); Self.shared = self }
    @Published var status = "Enable reminder notifications"
    var onToken: ((String) -> Void)?
    var onAction: (() -> Void)?
    private let center = UNUserNotificationCenter.current()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        center.delegate = self
        let done = UNNotificationAction(identifier: "done", title: "Done", options: [.foreground])
        let later = UNNotificationAction(identifier: "snooze", title: "In an hour", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "REMINDER", actions: [done,later], intentIdentifiers: [])])
        Task { await refresh() }
        return true
    }
    func refresh() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            status = "Reminder notifications enabled"
            UIApplication.shared.registerForRemoteNotifications()
        } else if settings.authorizationStatus == .denied { status = "Notifications are off in Settings" }
    }
    func enable() {
        Task {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert,.sound,.badge])
                if allowed { await refresh() }
                else { status = "Notifications are off in Settings" }
            } catch { status = "Couldn’t enable notifications. Try again." }
        }
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "pushToken")
        onToken?(token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        status = "Notification connection failed. Try enabling again."
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner,.sound,.list] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["reminder_id"] as? String, let version = info["version"] as? Int else { return }
        if ["done","snooze"].contains(response.actionIdentifier) {
            var pending = UserDefaults.standard.array(forKey: "reminderActions") as? [[String: Any]] ?? []
            var action: [String: Any] = ["id":id,"version":version,"action":response.actionIdentifier]
            if response.actionIdentifier == "snooze" { action["until"] = isoDate(Date().addingTimeInterval(3600)) }
            pending.append(action)
            UserDefaults.standard.set(pending, forKey: "reminderActions")
            onAction?()
        }
    }
}

struct ReminderItem: Identifiable {
    let id: String
    let title, context: String
    let version: Int
    let next: Date?
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        title = row["title"] as? String ?? ""
        context = row["context"] as? String ?? ""
        version = row["version"] as? Int ?? 1
        next = parseDate(row["next_notify_at"])
    }
}
