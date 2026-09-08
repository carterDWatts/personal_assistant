import XCTest
import AVFoundation
@testable import Assistant

@MainActor final class VoiceTests: XCTestCase {
    func testRelayRegionTiming() async throws {
        let account = Account.shared
        let token = try await account.accessToken()
        for region: String? in [nil, "us-east-1"] {
            let socket = RelaySocket(region: region)
            defer { socket.close() }
            let (status, boot) = try await socket.request(
                ["action": "bootstrap", "device_id": account.deviceID, "args": [:]], token: token)
            XCTAssertEqual(status, 200)
            let cursor = boot["cursor"] ?? 0
            for _ in 0..<5 {
                let start = Date()
                let (status, _) = try await socket.request(
                    ["action": "events", "device_id": account.deviceID, "args": ["after": cursor]], token: token)
                XCTAssertEqual(status, 200)
                print("Relay round trip:", region ?? "automatic", Date().timeIntervalSince(start))
            }
        }
    }

    func testModeCuesDoNotBecomeSpeech() async throws {
        let voice = LiveVoice()
        defer { voice.stop() }
        voice.onUtterance = { XCTFail("A mode cue was transcribed: \($0)") }
        voice.onPlaybackStarted = { XCTFail("A mode cue was counted as a spoken reply") }
        try await voice.beginReplay()
        for cue in VoiceCue.allCases {
            let buffer = try XCTUnwrap(cue.buffer())
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertLessThan(Double(buffer.frameLength) / buffer.format.sampleRate, 0.1)
            XCTAssertEqual(samples[0], 0, accuracy: 0.00001)
            XCTAssertEqual(samples[Int(buffer.frameLength) - 1], 0, accuracy: 0.00001)
            XCTAssertLessThan((0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 1, 0.06)
            voice.feedReplay(buffer)
            try await Task.sleep(for: .milliseconds(100))
        }
        voice.prepareReply()
        let quiet = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!, frameCapacity: 2400))
        quiet.frameLength = 2400
        quiet.floatChannelData?[0].initialize(repeating: 0, count: 2400)
        for _ in 0..<15 {
            voice.feedReplay(quiet)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(voice.transcript.isEmpty)
        XCTAssertFalse(voice.speaking)
    }

    func testRecordedSpeechIsRecognizedAsOneUtterance() async throws {
        let voice = LiveVoice()
        defer { voice.stop() }
        let heard = expectation(description: "One complete utterance")
        var utterances: [String] = []
        voice.onError = { XCTFail($0) }
        voice.onUtterance = { text in utterances.append(text); if utterances.count == 1 { heard.fulfill() } }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "input", withExtension: "wav"))
        try await voice.replay(file)
        await fulfillment(of: [heard], timeout: 10)
        XCTAssertEqual(utterances.count, 1)
        XCTAssertTrue(utterances.first?.lowercased().contains("one short greeting") == true, utterances.description)
    }

    func testPauseInsideSentenceDoesNotSubmitEarly() async throws {
        let voice = LiveVoice()
        defer { voice.stop() }
        var utterances: [String] = []
        voice.onUtterance = { utterances.append($0) }
        voice.onError = { XCTFail($0) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pause", withExtension: "wav"))
        try await voice.replay(file)
        XCTAssertEqual(utterances.count, 1, utterances.description)
        XCTAssertTrue(utterances.first?.lowercased().contains("does this take input") == true, utterances.description)
    }

    func testPlaybackEchoDoesNotSubmitAUserTurn() async throws {
        let voice = LiveVoice()
        defer { voice.stop() }
        let started = expectation(description: "Playback started")
        var falseTurns: [String] = []
        voice.onUtterance = { falseTurns.append($0) }
        voice.onPlaybackStarted = { started.fulfill() }
        voice.onError = { XCTFail($0) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "input", withExtension: "wav"))
        try await voice.beginReplay()
        voice.play(file, text: "This is a voice timing test. Please reply with one short greeting.")
        await fulfillment(of: [started], timeout: 5)
        // Inject the speaker waveform as recognizer input. This tests residual
        // echo rejection independently of physical acoustic cancellation.
        try await voice.feedRecording(file)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(falseTurns.isEmpty, "Playback became user speech: \(falseTurns)")
    }

    func testDifferentSpeechInterruptsPlayback() async throws {
        let voice = LiveVoice()
        defer { voice.stop() }
        let started = expectation(description: "Playback started")
        var interrupted = false
        var utterances: [String] = []
        voice.onPlaybackStarted = { started.fulfill() }
        voice.onSpeech = { interrupted = true; voice.silencePlayback() }
        voice.onUtterance = { utterances.append($0) }
        voice.onError = { XCTFail($0) }
        let playing = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "input", withExtension: "wav"))
        let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "interrupt", withExtension: "wav"))
        try await voice.beginReplay()
        voice.play(playing, text: "This is a voice timing test. Please reply with one short greeting.")
        await fulfillment(of: [started], timeout: 5)
        try await voice.feedRecording(input)
        XCTAssertTrue(interrupted)
        XCTAssertEqual(utterances.count, 1, utterances.description)
        XCTAssertTrue(utterances.first?.lowercased().contains("tomorrow") == true, utterances.description)
    }

    func testRecognitionAndCloudPlayback() async throws {
        XCTAssertTrue(Account.shared.signedIn, "Sign in to the test account before running cloud timing tests.")
        guard Account.shared.signedIn else { return }
        let voice = LiveVoice()
        let transport = RelayTransport()
        defer { voice.stop(); transport.close() }
        let ready = expectation(description: "Cloud connected")
        let heard = expectation(description: "Recognized one utterance")
        let audio = expectation(description: "First audio played")
        let finished = expectation(description: "Speech finished")
        var submitted: Date?
        var endOfInput: Date?
        var firstAudio: TimeInterval?
        var firstText: TimeInterval?
        var terminal = false
        var chunks = 0
        var recognized = ""
        let configuredModel = ProcessInfo.processInfo.environment["ASSISTANT_TEST_MODEL"] ?? ""
        let model = configuredModel.contains("/") ? configuredModel : nil
        var didConnect = false
        voice.onError = { XCTFail($0) }
        voice.onUtterance = { text in
            guard submitted == nil else { XCTFail("Unexpected extra utterance: \(text)"); return }
            recognized = text
            endOfInput = voice.lastInputSound
            submitted = Date()
            heard.fulfill()
            transport.send(text, id: UUID(), speech: true, model: model)
        }
        voice.onPlaybackStarted = {
            guard firstAudio == nil, let submitted else { return }
            firstAudio = Date().timeIntervalSince(endOfInput ?? submitted)
            audio.fulfill()
        }
        let receiver = Task {
            for await event in transport.events {
                print("Relay event:", event["type"] ?? "unknown")
                switch event["type"] as? String {
                case "ready":
                    if !didConnect { didConnect = true; ready.fulfill() }
                case "delta":
                    if firstText == nil, let submitted { firstText = Date().timeIntervalSince(submitted) }
                case "timing":
                    print("Host timing:", event.filter { $0.key.hasSuffix("_seconds") })
                case "speech":
                    if submitted != nil, let text = event["text"] as? String,
                       let link = event["url"] as? String, let url = URL(string: link) {
                        chunks += 1
                        voice.play(url, text: text)
                    }
                case "speech_end":
                    if submitted != nil && !terminal {
                        terminal = true
                        XCTAssertEqual(event["status"] as? String, "success")
                        finished.fulfill()
                    }
                case "error": XCTFail(event["text"] as? String ?? "Cloud error")
                default: break
                }
            }
        }
        defer { receiver.cancel() }
        transport.connect(clear: false)
        await fulfillment(of: [ready], timeout: 15)
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "input", withExtension: "wav"))
        try await voice.replay(file)
        await fulfillment(of: [heard, audio, finished], timeout: 30)
        XCTAssertTrue(recognized.lowercased().contains("voice timing test"), recognized)
        XCTAssertGreaterThan(chunks, 0)
        XCTAssertGreaterThan(transport.socketResponses, 0, "The persistent connection fell back to HTTP")
        // Wait for the actual player callbacks, not just the host's speech_end event.
        for _ in 0..<150 where voice.speaking { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(voice.speaking, "Playback did not finish")
        let measurement = "Endpoint: \(submitted?.timeIntervalSince(endOfInput ?? Date()) ?? -1)s; first text: \(firstText ?? -1)s; first audio after speech: \(firstAudio ?? -1)s; chunks: \(chunks)"
        let attachment = XCTAttachment(string: measurement)
        attachment.lifetime = .keepAlways
        add(attachment)
        print(measurement)
        XCTAssertLessThan(try XCTUnwrap(firstAudio), 3, measurement)
    }
}
