import XCTest

/// The web screen without the model: it loads, navigates, keeps drafts, and shows its controls to accessibility.
final class ScreenUITests: XCTestCase {
    func testNavigationAndDrafts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["SELF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["MACHINES"].exists)
        app.buttons["Back"].tap()

        app.buttons["New thread"].tap()
        let composer = app.textViews["Message Mycroft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("a draft that survives")
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        app.buttons["Back"].tap()

        // The draft is kept in the screen's saved state, across a relaunch too.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).firstMatch.tap()
        XCTAssertTrue(app.textViews["Message Mycroft"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["Message Mycroft"].value as? String, "a draft that survives")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Screenshots of every screen, for looking at the design (attachments in the result bundle).
    func testTour() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        snap(app, "home")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).firstMatch.tap()
        XCTAssertTrue(app.textViews["Message Mycroft"].waitForExistence(timeout: 10))
        sleep(2)
        let toolRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'self_'")).firstMatch
        if toolRow.exists { toolRow.tap() }
        snap(app, "thread")
        app.textViews["Message Mycroft"].tap()
        app.textViews["Message Mycroft"].typeText("Keyboard up")
        sleep(1)
        snap(app, "keyboard")
        app.buttons["Back"].tap()
        app.buttons["Settings"].tap()
        sleep(2)
        snap(app, "settings")
        app.swipeUp()
        snap(app, "settings-2")
        app.buttons["Back"].tap()
        app.buttons["Talk to Mycroft"].tap()
        sleep(3)
        snap(app, "voice")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
