import XCTest
import Speech
@testable import Assistant

final class MeetingTests: XCTestCase {
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
