import AVFoundation

enum MeetingMedia {
    /// Export directly from the selected file, so a large video is never copied into the library.
    static func extractAudio(from source: URL, to destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MediaFailure("An audio file already exists at this destination.")
        }
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw MediaFailure("This recording has no audio track to transcribe.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaFailure("I couldn’t read this recording. Try an MP4, MOV, M4A, MP3 or WAV file.")
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        export.metadata = []
        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    export.exportAsynchronously {
                        switch export.status {
                        case .completed: continuation.resume()
                        case .cancelled: continuation.resume(throwing: CancellationError())
                        default: continuation.resume(throwing: export.error ?? MediaFailure("Audio extraction failed. Check available storage and try again."))
                        }
                    }
                }
            } onCancel: { export.cancelExport() }
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private struct MediaFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
