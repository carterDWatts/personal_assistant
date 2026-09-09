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
        app.buttons["Cancel notification reply"].tap()
        XCTAssertTrue(app.staticTexts["Your report is ready."].waitForNonExistence(timeout: 5))
        app.buttons["Open inbox"].tap()
        XCTAssertTrue(app.staticTexts["Your report is ready."].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inbox"; screenshot.lifetime = .keepAlways; add(screenshot)
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
        XCTAssertTrue(app.buttons["Attach photos"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Email drafts"].exists)
        let input = app.textFields["Reply"]
        input.tap(); input.typeText("Write an email")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let card = app.buttons["email-draft-sample-draft"]
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
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
