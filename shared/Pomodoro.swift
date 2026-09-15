import SwiftUI
import UserNotifications

@MainActor final class Pomodoro: NSObject, ObservableObject {
    static let shared = Pomodoro()
    @Published private(set) var state: PomodoroState
    @Published var presented = false
    @Published private(set) var notice = ""
    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private var task: Task<Void, Never>?
    private let key = "pomodoro"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: "pomodoro").flatMap { try? JSONDecoder().decode(PomodoroState.self, from: $0) } ?? PomodoroState()
        super.init()
        #if os(macOS)
        if center.delegate == nil { center.delegate = self }
        #endif
        refresh()
        schedule()
    }
    func refresh() {
        state.reconcile(at: Date()); save()
    }
    func start() {
        cancelAlert(); state.start(at: Date()); save(); schedule()
    }
    func pause() {
        cancelAlert(); state.pause(at: Date()); save()
    }
    func reset() {
        cancelAlert(); state.reset(); notice = ""; save()
    }
    func configure(focus: Int? = nil, rest: Int? = nil, topic: String? = nil) {
        if let topic { state.topic = topic }
        if state.status == .ready || state.status == .finished {
            if let focus { state.focusMinutes = min(180, max(1, focus)) }
            if let rest { state.breakMinutes = min(60, max(1, rest)) }
            if state.status == .ready { state.remaining = state.duration }
        }
        save()
    }
    private func save() { defaults.set(try? JSONEncoder().encode(state), forKey: key) }
    private func cancelAlert() {
        task?.cancel(); task = nil
        if let id = state.runID?.uuidString {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }
    private func schedule() {
        guard state.status == .running, let end = state.deadline, let id = state.runID else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                guard !Task.isCancelled, state.runID == id, state.status == .running else { return }
                if allowed && end > Date() {
                    let content = UNMutableNotificationContent()
                    content.title = AssistantIdentity.name
                    content.body = state.phase == .focus ? "Your focus timer is finished. Ready for a break?" : "Your break is finished. Ready to focus again?"
                    content.sound = .default; content.userInfo = ["pomodoro": true]
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
                    try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
                    if Task.isCancelled { center.removePendingNotificationRequests(withIdentifiers: [id.uuidString]); return }
                    notice = ""
                } else if !allowed { notice = "Notifications are off. The timer still runs; enable notifications in Settings for an alert." }
            } catch { notice = "The timer is running, but I couldn’t schedule its alert." }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            guard state.runID == id, state.status == .running else { return }
            refresh()
        }
    }
}

#if os(macOS)
extension Pomodoro: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["pomodoro"] as? Bool == true else { return }
        await MainActor.run { self.refresh(); self.presented = true }
    }
}
#endif

struct PomodoroButton: View {
    @ObservedObject var timer: Pomodoro
    let accent: Color
    var body: some View {
        if timer.state.status != .ready {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button { timer.refresh(); timer.presented = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: timer.state.status == .paused ? "pause.circle" : "timer")
                        Text(timer.state.title)
                        Text(timer.state.status == .finished ? "Finished" : timer.state.clock(at: context.date)).monospacedDigit()
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.font(.callout).foregroundStyle(accent).padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open focus timer")
            }
        }
    }
}

struct PomodoroView: View {
    @ObservedObject var timer: Pomodoro
    let palette: Palette
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    private var state: PomodoroState { timer.state }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Focus timer").font(.title2.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close focus timer")
                }
                TextField("What are you focusing on?", text: Binding(get: { state.topic }, set: { timer.configure(topic: $0) }))
                    .textFieldStyle(.plain).padding(14).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Focus topic")
                VStack(spacing: 10) {
                    Mark(palette: palette).frame(width: 48, height: 48)
                    Text(state.status == .paused ? "Paused" : state.title).font(.headline).foregroundStyle(palette.muted)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(state.clock(at: context.date)).font(.system(size: 72, weight: .light, design: .rounded)).monospacedDigit()
                            .accessibilityIdentifier("Focus countdown")
                        ProgressView(value: min(1, max(0, 1 - state.seconds(at: context.date) / state.duration)))
                            .tint(palette.accent)
                    }
                    if state.status == .finished {
                        Text(state.phase == .focus ? "A little breathing room. Start your break when you’re ready." : "Ready for another stretch?")
                            .font(.callout).foregroundStyle(palette.muted).multilineTextAlignment(.center)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
                HStack(spacing: 14) {
                    Button("Reset") { timer.reset() }.buttonStyle(.bordered).accessibilityLabel("Reset focus timer")
                    Button(action: { state.status == .running ? timer.pause() : timer.start() }) {
                        Text(state.status == .running ? "Pause" : state.status == .paused ? "Resume" : state.status == .finished ? (state.phase == .focus ? "Start break" : "Start focus") : (state.phase == .focus ? "Start focus" : "Start break"))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).tint(palette.accent)
                }
                VStack(spacing: 16) {
                    Stepper("Focus · \(state.focusMinutes) min", value: Binding(get: { state.focusMinutes }, set: { timer.configure(focus: $0) }), in: 1...180).accessibilityIdentifier("Focus length")
                    Stepper("Break · \(state.breakMinutes) min", value: Binding(get: { state.breakMinutes }, set: { timer.configure(rest: $0) }), in: 1...60)
                }.disabled(state.status == .running || state.status == .paused)
                if !timer.notice.isEmpty { Text(timer.notice).font(.footnote).foregroundStyle(palette.muted) }
                Text("Start each phase when you’re ready. Finishing a timer doesn’t mark your task done.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }.padding(24)
        }.background(palette.background).foregroundStyle(palette.ink)
        .onAppear { timer.refresh() }
        .onChange(of: scene) { _ in timer.refresh() }
        #if os(macOS)
        .frame(width: 420, height: 620)
        #endif
    }
}
