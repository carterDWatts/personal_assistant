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
        #if DEBUG
        // Exercise notification delivery and navigation without a production push token.
        if ProcessInfo.processInfo.arguments.contains("--chat-reply-check") {
            Task {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                let content = UNMutableNotificationContent()
                content.title = AssistantIdentity.name; content.body = "Your test reply is ready."
                content.userInfo = ["chat_reply": true, "turn_id": UUID().uuidString]
                try? await center.add(UNNotificationRequest(identifier: "chat-reply-check", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 12, repeats: false)))
            }
        }
        #endif
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
    func clearChatReplies() {
        Task {
            let notices = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: notices.filter {
                $0.request.content.userInfo["chat_reply"] as? Bool == true
            }.map { $0.request.identifier })
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["chat_reply"] as? Bool == true || notification.request.content.userInfo["task_update"] as? Bool == true { return [] }
        return [.banner,.sound,.list]
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["chat_reply"] as? Bool == true {
            UserDefaults.standard.set(true, forKey: "openChatReply")
            UserDefaults.standard.removeObject(forKey: "notificationDiscussion")
            clearChatReplies()
            onAction?()
            return
        }
        if info["pomodoro"] as? Bool == true {
            Pomodoro.shared.refresh(); Pomodoro.shared.presented = true
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let kind = info["notice_id"] != nil ? "notice" : "reminder"
            if let id = (info["notice_id"] ?? info["reminder_id"]) as? String {
                var selection = ["kind":kind,"id":id,"title":response.notification.request.content.body]
                if let mid = info["message_id"] { selection["message_id"] = String(describing: mid) }
                UserDefaults.standard.set(selection, forKey: "notificationDiscussion")
                onAction?()
            }
            return
        }
        guard let id = info["reminder_id"] as? String, let version = info["version"] as? Int else { return }
        if ["done","snooze"].contains(response.actionIdentifier) {
            var pending = UserDefaults.standard.array(forKey: "reminderActions") as? [[String: Any]] ?? []
            var action: [String: Any] = ["id":id,"version":version,"action":response.actionIdentifier,"request_id":UUID().uuidString]
            if response.actionIdentifier == "snooze" { action["until"] = isoDate(Date().addingTimeInterval(3600)) }
            pending.append(action)
            UserDefaults.standard.set(pending, forKey: "reminderActions")
            onAction?()
        }
    }
}

struct ReminderItem: Identifiable {
    let id: String
    let title, context, severity: String
    let version: Int
    let next: Date?
    let start, end: Date?
    var section: String {
        if let end, end < Date() { return "Needs review" }
        if let start, start < Calendar.current.startOfDay(for: Date()) { return "Needs review" }
        if let start, start >= Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)) { return "Later" }
        return "Today"
    }
    let alarmAt: Date?
    init(_ row: [String: Any]) {
        id = row["id"] as? String ?? ""
        title = row["title"] as? String ?? ""
        context = row["context"] as? String ?? ""
        severity = row["severity"] as? String ?? "normal"
        version = row["version"] as? Int ?? 1
        alarmAt = parseDate(row["alarm_at"])
        next = parseDate(row["next_notify_at"])
        start = parseDate(row["window_start"]); end = parseDate(row["window_end"])
    }
}
