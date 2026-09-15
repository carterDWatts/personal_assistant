import Foundation

@main struct PomodoroCheck {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var timer = PomodoroState()
        timer.start(at: now)
        precondition(timer.seconds(at: now.addingTimeInterval(100)) == 1400)
        timer.pause(at: now.addingTimeInterval(100))
        precondition(timer.seconds(at: now.addingTimeInterval(500)) == 1400)
        var restored = try JSONDecoder().decode(PomodoroState.self, from: JSONEncoder().encode(timer))
        precondition(restored.status == .paused && restored.remaining == 1400)
        restored.start(at: now.addingTimeInterval(500))
        precondition(restored.deadline == now.addingTimeInterval(1900))
        restored = try JSONDecoder().decode(PomodoroState.self, from: JSONEncoder().encode(restored))
        restored.reconcile(at: now.addingTimeInterval(10_000))
        precondition(restored.status == .finished && restored.phase == .focus)
        precondition(restored.finishedIntervals == 1)
        restored.reconcile(at: now.addingTimeInterval(20_000))
        precondition(restored.finishedIntervals == 1, "An expired timer must finish only once after relaunch")
        restored.start(at: now.addingTimeInterval(20_000))
        precondition(restored.phase == .rest && restored.remaining == 300)
        restored.reset()
        precondition(restored.status == .ready && restored.deadline == nil && restored.runID == nil)
        var delayed = PomodoroState()
        delayed.start(at: now)
        delayed.pause(at: now.addingTimeInterval(2000))
        precondition(delayed.status == .finished, "Pausing after the deadline must not resurrect an expired timer")
        print("Focus timers preserve remaining time, survive relaunch, and wait between phases.")
    }
}
