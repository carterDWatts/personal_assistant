import XCTest

final class EmailReviewTests: XCTestCase {
    func testRecordingCanChoosePhotosWithoutLeavingChat() {
        let app = XCUIApplication(); app.launchArguments = ["--sample"]; app.launch()
        XCTAssertTrue(app.buttons["More options"].waitForExistence(timeout: 15))
        app.buttons["More options"].tap()
        app.buttons["Record or import conversation"].tap()
        XCTAssertTrue(app.buttons["Import recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Recording name (optional)"].exists)
        app.buttons["Recording options"].tap()
        XCTAssertTrue(app.textFields["Recording name (optional)"].waitForExistence(timeout: 5))
        app.buttons["Recording options"].tap()
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "Recording imports"; screen.lifetime = .keepAlways; add(screen)
        app.buttons["Import recording"].tap()
        XCTAssertTrue(app.buttons["Choose from Files"].exists)
        app.buttons["Choose from Photos"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(app.buttons["Import recording"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pause"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 5))
    }

    func testSendingKeepsLatestReplyVisibleAfterKeyboardCollapses() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "--scroll-stress", "-draft", ""]; app.launch()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("First line.\nSecond line.\nThird line.\nFourth line.\nFifth line.\nSixth line.")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let reply = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Latest reply ends here.'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Send message"].waitForExistence(timeout: 5))
        let visible = NSPredicate { _, _ in
            reply.exists && reply.frame.maxY > 200 && reply.frame.maxY < input.frame.minY
        }
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["Scroll to latest"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chat after send"; screenshot.lifetime = .keepAlways; add(screenshot)

        app.scrollViews["Conversation"].swipeDown()
        let latest = app.buttons["Scroll to latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(latest.exists)
    }

    func testLongDraftRemainsEditableAndScrolls() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "-draft", ""]; app.launch()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        let draft = (1...20).map { "Line \($0) of this longer message." }.joined(separator: "\n")
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertLessThan(input.frame.height, 200)
        input.swipeDown(); input.swipeUp()
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
    }

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
    func testFailedConnectionShowsRetryAndCanBeDismissed() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "--connection", "--connection-failure"]; app.launch()
        let connect = app.buttons["Connect Google"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15)); connect.tap()
        XCTAssertTrue(app.staticTexts["Google sign-in failed."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try again"].exists)
        app.buttons["Try again"].tap()
        XCTAssertTrue(app.staticTexts["Google sign-in failed."].waitForExistence(timeout: 5))
        app.buttons["Dismiss connection"].tap()
        XCTAssertTrue(app.buttons["Try again"].waitForNonExistence(timeout: 5))
    }
    func testUnconfiguredNotionExplainsWhyNoBrowserOpened() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "--connection", "--connection-unconfigured"]; app.launch()
        let connect = app.buttons["Connect Notion"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15)); connect.tap()
        XCTAssertTrue(app.staticTexts["I can’t open Notion sign-in yet. The app’s developer registration still needs to be completed."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertTrue(app.buttons["Dismiss connection"].exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
    }
    func testSuccessfulConnectionClosesTheCard() {
        let app = XCUIApplication(); app.launchArguments = ["--sample", "--connection"]; app.launch()
        let connect = app.buttons["Connect Google"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15)); connect.tap()
        XCTAssertTrue(app.buttons["Dismiss connection"].waitForNonExistence(timeout: 5))
    }
    func testDraftShowsRecipientsAndRequiresSendButton() {
        let app = XCUIApplication()
        app.launchArguments = ["--sample"]
        app.launch()
        XCTAssertTrue(app.buttons["Attach photos"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Email drafts"].exists)
        let input = app.textViews["Message"]
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
