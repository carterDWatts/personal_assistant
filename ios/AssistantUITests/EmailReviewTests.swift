import XCTest

final class EmailReviewTests: XCTestCase {
    func testInboxAddsOnlySelectedMessageToChat() {
        let app = XCUIApplication(); app.launchArguments = ["--sample"]; app.launch()
        XCTAssertTrue(app.buttons["Open inbox"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Your report is ready."].exists)
        app.buttons["Open inbox"].tap()
        XCTAssertTrue(app.staticTexts["Your report is ready."].waitForExistence(timeout: 5))
        app.staticTexts["Your report is ready."].tap()
        XCTAssertTrue(app.buttons["Open inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Your report is ready."].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replying to'")).firstMatch.exists)
    }
    func testFailedConnectionDisappears() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "--connection", "--connection-failure"]; app.launch()
        let connect = app.buttons["Connect Google"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15)); connect.tap()
        XCTAssertTrue(connect.waitForNonExistence(timeout: 5))
    }
    func testDraftShowsRecipientsAndRequiresSendButton() {
        let app = XCUIApplication()
        app.launchArguments = ["--sample"]
        app.launch()
        let drafts = app.buttons["Email drafts"]
        XCTAssertTrue(drafts.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Attach photos"].exists)
        drafts.tap()
        let subject = app.staticTexts["Friday coffee"]
        XCTAssertTrue(subject.waitForExistence(timeout: 10))
        subject.tap()
        XCTAssertTrue(app.staticTexts["me@example.com"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["alex@example.com"].exists)
        XCTAssertFalse(app.staticTexts["Sent through Gmail."].exists)
        XCTAssertTrue(app.buttons["Send email"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Draft review"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Send email"].tap()
        XCTAssertTrue(app.staticTexts["Sent through Gmail."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send email"].exists)
    }
}
