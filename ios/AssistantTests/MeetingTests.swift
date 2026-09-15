import XCTest
import Speech
import AVFoundation
@testable import Assistant

final class MeetingTests: XCTestCase {
    func testFileReaderResumesAtSavedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("long.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000*95)!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.1) }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let reader = try AudioFileChunks(url: source)
        let firstValue = try await reader.next()
        let first = try XCTUnwrap(firstValue)
        defer { try? FileManager.default.removeItem(at: first.url) }
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.end, 45, accuracy: 0.001)
        let resumed = try AudioFileChunks(url: source, offset: first.end)
        let nextValue = try await resumed.next()
        let next = try XCTUnwrap(nextValue)
        defer { try? FileManager.default.removeItem(at: next.url) }
        XCTAssertEqual(next.offset, first.end, accuracy: 0.001)
        XCTAssertEqual(next.end, 90, accuracy: 0.001)
        let lastValue = try await resumed.next()
        let last = try XCTUnwrap(lastValue)
        defer { try? FileManager.default.removeItem(at: last.url) }
        XCTAssertEqual(last.offset, next.end, accuracy: 0.001)
        XCTAssertEqual(last.end, 95, accuracy: 0.001)
        let end = try await resumed.next()
        XCTAssertNil(end)
    }

    @MainActor func testAudioImportTranscribesWithoutTakingOverChat() async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw XCTSkip("Run ReplayPermissions first to authorize speech.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(directory: root)
        let capture = MeetingCapture(library: library)
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "input", withExtension: "wav"))
        capture.importAudio(file, title: "Fixture conversation", runtime: "codex")
        XCTAssertTrue(capture.working)
        let chat = Chat(transport: MockTransport())
        chat.connect()
        let deadline = Date().addingTimeInterval(90)
        while capture.working && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(capture.working)
        XCTAssertEqual(capture.error, "")
        XCTAssertTrue(chat.connected, "Transcription must leave the conversation connected")
        let doc = try XCTUnwrap(library.selected)
        XCTAssertTrue(doc.transcript.lowercased().contains("voice timing test"), doc.transcript)
        XCTAssertTrue(doc.ended)
        XCTAssertFalse(doc.batches.isEmpty)
        XCTAssertNotNil(library.context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent(try XCTUnwrap(doc.audioName)).path))
    }
}
