import Foundation

struct PomodoroState: Codable {
    enum Phase: String, Codable { case focus, rest }
    enum Status: String, Codable { case ready, running, paused, finished }
    var phase: Phase = .focus
    var status: Status = .ready
    var focusMinutes = 25
    var breakMinutes = 5
    var topic = ""
    var remaining: TimeInterval = 25 * 60
    var deadline: Date?
    var runID: UUID?
    var finishedIntervals = 0

    var duration: TimeInterval { TimeInterval((phase == .focus ? focusMinutes : breakMinutes) * 60) }
    var title: String { phase == .focus ? "Focus" : "Break" }
    func seconds(at now: Date) -> TimeInterval { max(0, deadline.map { $0.timeIntervalSince(now) } ?? remaining) }
    func clock(at now: Date) -> String {
        let seconds = Int(ceil(seconds(at: now)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    mutating func reconcile(at now: Date) {
        guard status == .running, let deadline, now >= deadline else { return }
        status = .finished; remaining = 0; self.deadline = nil
        if phase == .focus { finishedIntervals += 1 }
    }
    mutating func start(at now: Date) {
        reconcile(at: now)
        guard status != .running else { return }
        if status == .finished {
            phase = phase == .focus ? .rest : .focus
            remaining = duration
        } else if status == .ready { remaining = duration }
        status = .running; runID = UUID(); deadline = now.addingTimeInterval(remaining)
    }
    mutating func pause(at now: Date) {
        reconcile(at: now)
        guard status == .running else { return }
        remaining = seconds(at: now); deadline = nil; status = .paused
    }
    mutating func reset() {
        phase = .focus; status = .ready; deadline = nil; runID = nil; remaining = duration
    }
}
