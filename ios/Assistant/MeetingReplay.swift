#if DEBUG
import SwiftUI

/// Runs the real file-transcription path on a fixture without chat, network, or microphone access.
struct MeetingReplayView: View {
    @State private var result = "Transcribing fixture…"
    var body: some View {
        Text(result).padding().task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let library = MeetingLibrary(directory: documents.appendingPathComponent("meeting-fixture"))
            let capture = MeetingCapture(library: library)
            capture.importAudio(documents.appendingPathComponent("meeting-replay.wav"), title: "Fixture", runtime: "codex")
            let deadline = Date().addingTimeInterval(120)
            while capture.working && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            let report: [String: Any] = ["finished": !capture.working, "error": capture.error,
                "text": library.selected?.transcript ?? "", "batches": library.selected?.batches.count ?? 0]
            if let data = try? JSONSerialization.data(withJSONObject: report) {
                try? data.write(to: documents.appendingPathComponent("meeting-result.json"), options: .atomic)
            }
            result = capture.error.isEmpty ? library.selected?.transcript ?? "No transcript" : capture.error
        }
    }
}
#endif
