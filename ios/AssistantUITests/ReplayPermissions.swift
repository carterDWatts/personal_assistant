import XCTest

final class ReplayPermissions: XCTestCase {
    func testAuthorizePrerecordedSpeech() {
        let app = XCUIApplication()
        app.launchEnvironment["ASSISTANT_VOICE_TEST"] = "1"
        app.launchArguments = ["--authorize-replay"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Testing voice · microphone off"].exists)
    }
}
