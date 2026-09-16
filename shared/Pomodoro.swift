import SwiftUI
import UserNotifications

@MainActor final class Pomodoro: NSObject, ObservableObject {
    static let shared = Pomodoro()
    @Published private(set) var state: PomodoroState
    @Published var presented = false
    @Published var displayOpen = false
    @Published private(set) var soundEnabled: Bool
    @Published private(set) var notice = ""
    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()
    private var task: Task<Void, Never>?
    private let key = "pomodoro"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.bool(forKey: "pomodoroSound")
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
    func setSound(_ enabled: Bool) {
        soundEnabled = enabled; defaults.set(enabled, forKey: "pomodoroSound")
        cancelAlert(); schedule()
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
                let allowed = try await center.requestAuthorization(options: soundEnabled ? [.alert, .sound] : [.alert])
                guard !Task.isCancelled, state.runID == id, state.status == .running else { return }
                if allowed && end > Date() {
                    let content = UNMutableNotificationContent()
                    content.title = AssistantIdentity.name
                    content.body = state.phase == .focus ? "Your focus timer is finished. Ready for a break?" : "Your break is finished. Ready to focus again?"
                    content.sound = soundEnabled ? .default : nil; content.userInfo = ["pomodoro": true]
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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.content.userInfo["pomodoro"] as? Bool == true, await MainActor.run(body: { self.displayOpen }) {
            return notification.request.content.sound == nil ? [] : [.sound]
        }
        return [.banner, .sound]
    }
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
                Button { timer.displayOpen = true } label: {
                    HStack {
                        Image(systemName: "square.stack.3d.up")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Focus display").font(.headline)
                            Text("A quiet stack. A clear change when it’s time.").font(.caption).foregroundStyle(palette.muted)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }.padding(16).background(palette.surface, in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open focus display")
                VStack(spacing: 16) {
                    Stepper("Focus · \(state.focusMinutes) min", value: Binding(get: { state.focusMinutes }, set: { timer.configure(focus: $0) }), in: 1...180).accessibilityIdentifier("Focus length")
                    Stepper("Break · \(state.breakMinutes) min", value: Binding(get: { state.breakMinutes }, set: { timer.configure(rest: $0) }), in: 1...60)
                }.disabled(state.status == .running || state.status == .paused)
                Toggle("Play a sound when time is up", isOn: Binding(get: { timer.soundEnabled }, set: { timer.setSound($0) }))
                    .tint(palette.accent)
                if !timer.notice.isEmpty { Text(timer.notice).font(.footnote).foregroundStyle(palette.muted) }
                Text("Start each phase when you’re ready. Finishing a timer doesn’t mark your task done.")
                    .font(.footnote).foregroundStyle(palette.muted)
            }.padding(24)
        }.background(palette.background).foregroundStyle(palette.ink)
        .accessibilityHidden(timer.displayOpen)
        .onAppear { timer.refresh() }
        .onChange(of: scene) { _ in timer.refresh() }
        #if os(iOS)
        .fullScreenCover(isPresented: $timer.displayOpen) { FocusDisplay(timer: timer) }
        #else
        .sheet(isPresented: $timer.displayOpen) { FocusDisplay(timer: timer).frame(width: 520, height: 680) }
        #endif
        #if os(macOS)
        .frame(width: 420, height: 620)
        #endif
    }
}

/// Scoped to the visible display; closing it restores the system's sleep policy.
@MainActor final class FocusDisplayWakeLock: ObservableObject {
    #if os(iOS)
    private var previous: Bool?
    #else
    private var activity: NSObjectProtocol?
    #endif
    func setEnabled(_ enabled: Bool) {
        #if os(iOS)
        if enabled, previous == nil {
            previous = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !enabled, let previous {
            UIApplication.shared.isIdleTimerDisabled = previous; self.previous = nil
        }
        #else
        if enabled, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled, reason: "Show the focus timer")
        } else if !enabled, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
        #endif
    }
}

struct FocusDisplay: View {
    @ObservedObject var timer: Pomodoro
    @StateObject private var wakeLock = FocusDisplayWakeLock()
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var state: PomodoroState { timer.state }
    private var finished: Bool { state.status == .finished }
    private var background: Color {
        finished ? Color(red: 0.91, green: 0.74, blue: 0.36) : state.phase == .focus
            ? Color(red: 0.20, green: 0.30, blue: 0.25) : Color(red: 0.28, green: 0.37, blue: 0.45)
    }
    private var ink: Color { finished ? Color(red: 0.15, green: 0.22, blue: 0.18) : Color(red: 0.93, green: 0.95, blue: 0.86) }
    private var title: String {
        if finished { return state.phase == .focus ? "Time for a break." : "Back to focus." }
        return state.status == .paused ? "Take your time." : state.phase == .focus ? "One thing at a time." : "A little breathing room."
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Text(state.status == .paused ? "Paused" : state.title).font(.headline)
                    Spacer()
                    Button { timer.displayOpen = false } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44).background(ink.opacity(0.09), in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Close focus display")
                }
                Spacer(minLength: 20)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let count = state.blocks(at: context.date)
                    VStack(spacing: 7) {
                        ForEach((0..<8).reversed(), id: \.self) { index in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(ink.opacity(index < count ? 0.94 : 0.10))
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(background.opacity(0.22)).frame(height: 5).padding(.horizontal, 2)
                                }
                                .frame(width: min(geometry.size.width * 0.66, 280) - CGFloat(index % 3) * 12,
                                       height: max(12, min(34, geometry.size.height * 0.039)))
                                .offset(x: CGFloat([0, 12, -8, 6, -12, 8, -4, 0][index]))
                        }
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: count)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Focus blocks")
                        .accessibilityValue(finished ? "Finished" : "\(count) of 8 blocks")
                }
                Spacer(minLength: 24)
                VStack(spacing: 12) {
                    Text(title).font(.system(size: 30, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
                        .accessibilityIdentifier("Focus display phase")
                    if !state.topic.isEmpty {
                        Text(state.topic).font(.body).lineLimit(2).multilineTextAlignment(.center).opacity(0.7)
                    }
                }.frame(maxWidth: .infinity)
                Spacer(minLength: 24)
                Button { state.status == .running ? timer.pause() : timer.start() } label: {
                    Text(state.status == .running ? "Pause" : state.status == .paused ? "Resume" : finished && state.phase == .focus ? "Start break" : "Start focus")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(ink.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(finished ? "Whenever you’re ready." : "The screen stays awake here.")
                    .font(.footnote).opacity(0.65).padding(.top, 14)
            }.padding(28).foregroundStyle(ink)
        }
        .background(background.ignoresSafeArea())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: finished)
        .onAppear { timer.refresh(); wakeLock.setEnabled(scene != .background) }
        .onChange(of: scene) { _ in timer.refresh(); wakeLock.setEnabled(scene != .background) }
        .onDisappear { wakeLock.setEnabled(false) }
        #if os(iOS)
        .statusBarHidden()
        #endif
    }
}
