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

        // A new thread is a draft: nothing is created until it is sent.
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).count
        app.buttons["New thread"].tap()
        let composer = app.textViews["Message Mycroft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["What should Mycroft do?"].exists)
        composer.tap()
        composer.typeText("a draft that survives")
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertTrue(app.buttons["Clear"].exists, "a field with text can be cleared")
        app.buttons["Back"].tap()
        let draftRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'a draft that survives'")).firstMatch
        XCTAssertTrue(draftRow.waitForExistence(timeout: 5), "the unsent draft is listed")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).count, rows, "no thread was created")

        // The draft is kept in the screen's saved state, across a relaunch too.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(draftRow.waitForExistence(timeout: 30))
        draftRow.tap()
        XCTAssertTrue(app.textViews["Message Mycroft"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["Message Mycroft"].value as? String, "a draft that survives")
        snap(app, "draft")
        app.buttons["Clear"].tap()
        // An empty field reports its placeholder.
        XCTAssertNotEqual(app.textViews["Message Mycroft"].value as? String, "a draft that survives")
        XCTAssertFalse(app.buttons["Clear"].exists)
        app.buttons["Back"].tap()
        XCTAssertFalse(draftRow.waitForExistence(timeout: 2), "an empty draft isn't listed")
    }

    /// The list's long-press menu, and the Settled shelf: settle a thread, find it in the shelf, bring it back.
    func testSettleAndMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        let title = first.label
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Settle"].exists)
        snap(app, "list-menu")
        app.buttons["Settle"].tap()
        let shelf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SETTLED'")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        snap(app, "settled-collapsed")
        shelf.tap()
        // Settled rows are slim: the title without the number.
        let name = title.components(separatedBy: " ").dropFirst().prefix(2).joined(separator: " ")
        let settled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label != 'New thread'", name)).firstMatch
        XCTAssertTrue(settled.waitForExistence(timeout: 5), "\(name) is in the shelf")
        snap(app, "settled-open")
        settled.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Un-settle"].waitForExistence(timeout: 5))
        app.buttons["Un-settle"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '01 '")).firstMatch.waitForExistence(timeout: 5))
    }

    /// A real run (needs the Simulator signed in): a new thread starts on send; while it works a message queues;
    /// stop pauses the queue and Resume sends it; the finished run folds into "Worked for"; Fork opens a copy.
    func testRunQueueAndFork() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        app.buttons["New thread"].tap()
        let composer = app.textViews["Message Mycroft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("UI test: call the now tool four times, one call at a time, then answer with one short line.")
        app.buttons["Send"].tap()

        let working = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Working'")).firstMatch
        XCTAssertTrue(working.waitForExistence(timeout: 30), "the capsule shows the run")
        composer.tap()
        composer.typeText("Then tell me the weekday.")
        XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 5), "while it works, send queues by default")
        app.buttons["Queue"].tap()
        let queued = app.buttons["1 queued"]
        XCTAssertTrue(queued.waitForExistence(timeout: 10))
        snap(app, "run-queued")
        queued.tap()
        // Buttons are uppercased by the style.
        XCTAssertTrue(app.buttons["STEER NOW"].waitForExistence(timeout: 5))
        snap(app, "queue-sheet")
        app.buttons["Done"].tap()

        // Stop keeps the queue, paused.
        app.buttons["Stop"].tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "a stop pauses the queue")
        snap(app, "queue-paused")
        resume.tap()
        XCTAssertTrue(working.waitForExistence(timeout: 30), "resuming sends the queued message")
        // The title button reads the title and the status.
        let idle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'UI test' AND label ENDSWITH 'IDLE'")).firstMatch
        XCTAssertTrue(idle.waitForExistence(timeout: 180), "the run ends")
        snap(app, "run-done")

        let fork = app.buttons.matching(NSPredicate(format: "label == 'Fork from this answer'"))
        XCTAssertTrue(fork.firstMatch.waitForExistence(timeout: 10))
        let worked = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'WORKED FOR' OR label BEGINSWITH 'STOPPED AFTER'"))
        XCTAssertGreaterThan(worked.count, 0, "finished runs fold their working")
        fork.element(boundBy: fork.count - 1).tap()
        let forked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fork · '")).firstMatch
        XCTAssertTrue(forked.waitForExistence(timeout: 15), "the fork opens")
        snap(app, "forked")
        app.buttons["Back"].tap()
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 10))
        snap(app, "list-after-run")
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

    /// Voice lives in every thread: the mic in the composer. With Apple's model chosen, the Simulator has no speech
    /// models, so starting fails, and says why.
    func testVoiceControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        choose(app, dictation: "Apple")
        app.buttons["Back"].tap()
        XCTAssertFalse(app.buttons["Talk to Mycroft"].exists, "the separate voice screen is gone")
        app.buttons["New thread"].tap()
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["Read aloud"].exists, "reading aloud is gone")
        snap(app, "voice-controls")
        app.buttons["Talk"].tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'speech'")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "starting the mic without speech models says why")
        snap(app, "voice-unavailable")
        XCTAssertTrue(app.buttons["Talk"].exists, "the mic is back to its resting state")
    }

    /// Settings → Dictation: Parakeet (bundled) by default, and switching to Apple and back sticks.
    func testDictationSetting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        choose(app, dictation: "Apple")
        snap(app, "dictation-apple")
        choose(app, dictation: "Parakeet v3")
        snap(app, "dictation-parakeet")
    }

    /// Opens Settings and picks a dictation model; it stays on the Settings screen.
    private func choose(_ app: XCUIApplication, dictation name: String) {
        if !app.staticTexts["DICTATION"].exists { app.buttons["Settings"].tap() }
        // WebKit reports role="radio" as a plain element whose value is 1 when checked.
        let options = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Parakeet v3", "Apple"]))
        let option = options[name]
        XCTAssertTrue(option.waitForExistence(timeout: 10), "Settings shows the \(name) option")
        option.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: option)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(options.matching(NSPredicate(format: "value == '1'")).count, 1, "one model is chosen")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
