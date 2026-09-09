import XCTest

final class EmailReviewTests: XCTestCase {
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
