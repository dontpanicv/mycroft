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
    }

    /// Add machine: the short command, and the network picker switching it to another of the phone's addresses.
    func testPairScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        let add = app.buttons["Add machine"]
        for _ in 0..<6 where !add.isHittable { app.swipeUp() }
        add.tap()
        let command = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'curl -fsS '")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 20))
        let first = command.label
        XCTAssertTrue(first.range(of: #"^curl -fsS [0-9.]+:\d+/[a-z2-9]{6} \| sh$"#, options: .regularExpression) != nil, first)
        sleep(1)
        snap(app, "pair")

        let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Network'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        sleep(1)
        snap(app, "pair-picker")
        let option = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'NetBird' OR label BEGINSWITH 'Tailscale'")).firstMatch
        guard option.waitForExistence(timeout: 5) else { return print("PAIR: no VPN address on this Mac to switch to") }
        option.tap()
        let switched = NSPredicate(format: "label != %@", first)
        expectation(for: switched, evaluatedWith: command)
        waitForExpectations(timeout: 5)
        print("PAIR: \(first) → \(command.label)")
        snap(app, "pair-vpn")
    }

    /// Voice lives in every thread: the mic in the composer and "Read aloud" in the header. The Simulator has no speech
    /// models, so starting fails, and says why.
    func testVoiceControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Talk to Mycroft"].exists, "the separate voice screen is gone")
        app.buttons["New thread"].tap()
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 10))
        // aria-pressed makes it a toggle to accessibility, not a plain button.
        XCTAssertTrue(app.descendants(matching: .any)["Read aloud"].exists)
        snap(app, "voice-controls")
        app.buttons["Talk"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'speech'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "starting the mic without speech models says why")
        snap(app, "voice-unavailable")
        XCTAssertTrue(app.buttons["Talk"].exists, "the mic is back to its resting state")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
