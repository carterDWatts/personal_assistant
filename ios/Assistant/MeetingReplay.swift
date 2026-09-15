#if DEBUG
import SwiftUI

/// Runs the real file-transcription path on a fixture without chat, network, or microphone access.
struct MeetingReplayView: View {
    @State private var result = "Transcribing fixture…"
    var body: some View {
        Text(result).accessibilityIdentifier("meeting-replay").padding().task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let library = MeetingLibrary(directory: documents.appendingPathComponent("meeting-fixture"))
            let capture = MeetingCapture(library: library)
            defer {
                if !capture.working {
                    try? FileManager.default.removeItem(at: library.directory)
                    try? FileManager.default.removeItem(at: documents.appendingPathComponent("meeting-replay.wav"))
                }
            }
            capture.importAudio(documents.appendingPathComponent("meeting-replay.wav"), title: "Fixture", runtime: "codex")
            let deadline = Date().addingTimeInterval(300)
            while capture.working && Date() < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { capture.cancelImport(); return }
            }
            if capture.working { capture.cancelImport() }
            let offscreen = UIApplication.shared.applicationState == .background
            let report: [String: Any] = ["backgroundAtCompletion": offscreen, "finished": !capture.working, "error": capture.error,
                "text": library.selected?.transcript ?? "", "batches": library.selected?.batches.count ?? 0,
                "state": library.selected?.processing?.state ?? "unknown", "offset": library.selected?.processing?.offset ?? 0]
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                try? data.write(to: documents.appendingPathComponent("meeting-result.json"), options: .atomic)
            }
            result = capture.error.isEmpty ? "Background: \(offscreen)\n" + (library.selected?.transcript ?? "No transcript") : capture.error
        }
    }
}
#endif
