import XCTest

final class AlarmUITests: XCTestCase {
    func testNativeAlarmActuallyAlerts() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("AlarmKit requires iOS 26") }
        let app = XCUIApplication()
        app.launchArguments = ["--alarm-check"]
        app.launch()
        app.buttons["Schedule test alarm"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(app.staticTexts["Alarm is ringing"].waitForExistence(timeout: 25))
        app.buttons["Stop test alarm"].tap()
        XCTAssertTrue(app.staticTexts["Alarm stopped"].exists)
    }
}
