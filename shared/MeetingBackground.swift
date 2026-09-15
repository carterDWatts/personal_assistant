import Foundation
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

/// User-started transcription can continue offscreen. Expiration always checkpoints the job.
@MainActor final class MeetingBackground {
    #if os(iOS)
    private var identifier: String?
    private var continued: AnyObject?
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    private var fraction = 0.0
    private var detail = "Preparing recording…"
    func begin(title: String, expiration: @escaping @MainActor () -> Void) {
        fraction = 0; detail = "Preparing recording…"
        if #available(iOS 26, *) {
            let id = (Bundle.main.bundleIdentifier ?? "com.carterwatts.assistant") + ".transcription." + UUID().uuidString
            identifier = id
            let scheduler = BGTaskScheduler.shared
            let registered = scheduler.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, self.identifier == id, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                    self.continued = task
                    task.progress.totalUnitCount = 1000
                    task.expirationHandler = { Task { @MainActor [weak self] in self?.end(success: false); expiration() } }
                    self.update(self.fraction, detail: self.detail)
                }
            }
            if registered {
                let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: detail)
                request.strategy = .fail
                do { try scheduler.submit(request); return }
                catch { /* Fall back to the limited background allowance. */ }
            }
            identifier = nil
        }
        fallback = UIApplication.shared.beginBackgroundTask(withName: "Transcribe recording") {
            Task { @MainActor [weak self] in self?.end(success: false); expiration() }
        }
    }
    func update(_ fraction: Double, detail: String) {
        self.fraction = fraction; self.detail = detail
        if #available(iOS 26, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(min(0.999, max(0, fraction)) * 1000)
            task.updateTitle(task.title, subtitle: detail)
        }
    }
    func end(success: Bool) {
        if #available(iOS 26, *), let task = continued as? BGContinuedProcessingTask {
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
        }
        continued = nil
        if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        identifier = nil
        if fallback != .invalid { UIApplication.shared.endBackgroundTask(fallback); fallback = .invalid }
    }
    #else
    func begin(title: String, expiration: @escaping @MainActor () -> Void) {}
    func update(_ fraction: Double, detail: String) {}
    func end(success: Bool) {}
    #endif
}
