import AVFoundation
import Combine

/// Bundled Pocket samples play immediately without a model request or a new chat turn.
@MainActor final class VoicePreview: ObservableObject {
    @Published private(set) var status = ""
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var restore: (() -> Void)?

    func play(_ id: String, voice: LiveVoice, ready: @escaping () -> Bool) {
        stop()
        guard let url = Bundle.main.url(forResource: "voice-" + (id.isEmpty ? "michael" : id), withExtension: "m4a") else {
            status = "Sample unavailable. This voice can still be used for replies."
            return
        }
        let token = generation
        status = ready() ? "Playing sample…" : "Sample will play after the reply."
        task = Task { [weak self] in
            while !ready() {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled, generation == token else { return }
            let wasMuted = voice.muted
            voice.setMuted(true)
            let activatedSession = !voice.active
            restore = {
                voice.setMuted(wasMuted)
                if activatedSession && !voice.active {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
            do {
                if activatedSession {
                    try AVAudioSession.sharedInstance().setCategory(.playback)
                    try AVAudioSession.sharedInstance().setActive(true)
                }
                player = try AVAudioPlayer(contentsOf: url)
                player?.prepareToPlay()
                guard player?.play() == true else { throw CocoaError(.fileReadUnknown) }
                status = "Playing sample…"
                while player?.isPlaying == true {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, generation == token else { return }
                }
                stop()
            } catch {
                stop()
                status = "The sample couldn’t play. Try again."
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        player?.stop(); player = nil
        restore?(); restore = nil
        status = ""
    }
}
