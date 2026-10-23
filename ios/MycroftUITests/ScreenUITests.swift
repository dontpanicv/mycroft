import XCTest

/// The web screen without the model: it loads, navigates, keeps drafts, and shows its controls to accessibility.
final class ScreenUITests: XCTestCase {
    /// A row of the thread list: its label is "title · when · …". The infinite chat's row, above the list, isn't one.
    static let threadRow = NSPredicate(format: "label CONTAINS ' · ' AND NOT label CONTAINS 'Draft' AND NOT label BEGINSWITH 'Mycroft ∞'")

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
        let rows = app.buttons.matching(Self.threadRow).count
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
        XCTAssertEqual(app.buttons.matching(Self.threadRow).count, rows, "no thread was created")

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
        // A thread that is working can't settle.
        let first = app.buttons.matching(Self.threadRow).matching(NSPredicate(format: "NOT label CONTAINS 'Working'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        let title = first.label.components(separatedBy: " · ")[0]
        first.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Settle"].exists)
        snap(app, "list-menu")
        app.buttons["Settle"].tap()
        let shelf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'SETTLED'")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        snap(app, "settled-collapsed")
        shelf.tap()
        // Earlier test runs leave threads with the same title: the settled one is the last on screen.
        let same = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title + " · "))
        let settled = same.element(boundBy: max(0, same.count - 1))
        XCTAssertTrue(settled.waitForExistence(timeout: 5), "\(title) is in the shelf")
        // A long press doesn't scroll to its element the way a tap does.
        for _ in 0..<12 where !settled.isHittable { app.swipeUp() }
        // A touch while the list still coasts only stops it.
        sleep(2)
        snap(app, "settled-open")
        settled.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Un-settle"].waitForExistence(timeout: 5))
        app.buttons["Un-settle"].tap()
        XCTAssertTrue(app.buttons.matching(Self.threadRow).firstMatch.waitForExistence(timeout: 5))
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
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: working)
        waitForExpectations(timeout: 180)
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

    /// A real run: the agent shows an image a tool returned and a piece of HTML, and both render in the thread.
    func testShowImageAndHTML() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        app.buttons["New thread"].tap()
        let composer = app.textViews["Message Mycroft"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("UI test: call self_preview with route #/settings, then show the latest image with the caption Settings preview, then show an HTML table of two fruits and their colours with a red header row. Then answer in one line.")
        app.buttons["Send"].tap()

        let image = app.images["Settings preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 240), "the shown image is in the thread")
        // WebKit reports the frame as a plain element named by its title.
        let frame = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Shown by Mycroft'")).firstMatch
        XCTAssertTrue(frame.waitForExistence(timeout: 120), "the shown HTML is in the thread")
        sleep(2)
        snap(app, "shown")
        XCTAssertGreaterThan(frame.frame.height, 60, "the frame is as tall as its content")
        // The thread follows the bottom, so the image's top may be under the header: tap its lower part.
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        snap(app, "shown-viewer")
        app.buttons["Close"].tap()
    }

    /// Screenshots of every screen, for looking at the design (attachments in the result bundle).
    func testTour() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["New thread"].waitForExistence(timeout: 30))
        snap(app, "home")
        app.buttons.matching(Self.threadRow).firstMatch.tap()
        XCTAssertTrue(app.textViews["Message Mycroft"].waitForExistence(timeout: 10))
        sleep(2)
        // A numbered tool row, not the title (which may mention a tool too).
        let toolRow = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]{2} self_.*'")).firstMatch
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

    /// Settings, the most used first: machines, then the generations, drawn as a tree, then the voice, the ChatGPT
    /// sign-in and the notices.
    func testSettingsOrderAndGenerationTree() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        let any = app.descendants(matching: .any)
        let machines = app.buttons["Add machine"]
        XCTAssertTrue(machines.waitForExistence(timeout: 10))
        let order = [
            machines,
            any.matching(NSPredicate(format: "label BEGINSWITH 'Shake the phone'")).firstMatch,
            any["Zoey"],
            any.matching(NSPredicate(format: "label CONTAINS 'ChatGPT'")).firstMatch,
            app.buttons["Open source notices"],
        ]
        let tops = order.map(\.frame.minY)
        XCTAssertEqual(tops, tops.sorted(), "machines, generations, voice, sign-in, notices")
        snap(app, "settings-top")
        let older = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show '")).firstMatch
        for _ in 0..<6 where !older.isHittable { app.swipeUp() }
        if older.exists { older.tap() }
        sleep(1)
        snap(app, "settings-generations")
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

    /// Voice lives in every thread: the mic and the conversation's wave in the composer, in a new thread and an existing
    /// one. One dictation model, so Settings has no choice of it. (The microphone isn't started: this Simulator's audio
    /// server aborts the app when anything opens it.)
    func testVoiceControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["CONVERSATION VOICE"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["DICTATION"].exists, "dictation has one model: nothing to choose")
        app.buttons["Back"].tap()
        app.buttons["New thread"].tap()
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Talk with Mycroft"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["Read aloud"].exists, "reading aloud is gone")
        snap(app, "voice-controls")
        app.buttons["Back"].tap()
        let first = app.buttons.matching(Self.threadRow).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Talk with Mycroft"].exists)
    }

    /// The app reopens on the thread that was open: the screen restores it while the brain is still waking up, and it
    /// must wait for the brain rather than call the thread missing.
    func testRelaunchIntoThread() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        let first = app.buttons.matching(Self.threadRow).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "needs a thread")
        first.tap()
        XCTAssertTrue(app.buttons["Talk with Mycroft"].waitForExistence(timeout: 10))
        let missing = app.staticTexts["This thread no longer exists."]
        XCTAssertFalse(missing.waitForExistence(timeout: 3))
        app.terminate()
        app.launchArguments = ["--slow-brain"]
        app.launch()
        XCTAssertTrue(app.buttons["Talk with Mycroft"].waitForExistence(timeout: 30), "the thread is open again")
        // Give the brain time to wake and the view to arrive.
        XCTAssertFalse(missing.waitForExistence(timeout: 15), "the restored thread is found")
        snap(app, "relaunched-into-thread")
    }

    /// Conversation mode: Settings offers the conversation voice (and no choice of model); the wave next to the mic
    /// swaps the composer for the conversation's dock, and ending it brings the composer back.
    func testConversationMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 30))
        app.buttons["Settings"].tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(app.buttons["Add machine"].waitForExistence(timeout: 10))
        XCTAssertFalse(any["Apple on-device"].exists, "no choice of model")
        snap(app, "settings-model")
        app.swipeUp()
        XCTAssertTrue(any["Zoey"].waitForExistence(timeout: 5), "Settings offers the voices")
        snap(app, "settings-voice")
        app.buttons["Back"].tap()
        // Starting the conversation opens the microphone, which aborts the app in a Simulator whose audio server can't
        // reach one: MYCROFT_MIC=1 where it works.
        guard ProcessInfo.processInfo.environment["MYCROFT_MIC"] == "1" else { return }

        app.buttons["New thread"].tap()
        let talk = app.buttons["Talk with Mycroft"]
        XCTAssertTrue(talk.waitForExistence(timeout: 10))
        talk.tap()
        let end = app.buttons["End conversation"]
        XCTAssertTrue(end.waitForExistence(timeout: 20), "the dock replaces the composer")
        XCTAssertFalse(app.buttons["Talk"].exists)
        XCTAssertTrue(app.staticTexts["LISTENING"].waitForExistence(timeout: 90), "it listens once the voice and mic are up")
        snap(app, "conversation-listening")
        if ProcessInfo.processInfo.environment["MYCROFT_LIVE"] == "1" {
            // Live: someone talks to the Mac's microphone (scripts can `say` a question) and Mycroft answers aloud.
            XCTAssertTrue(app.staticTexts["HEARING YOU"].waitForExistence(timeout: 120), "it hears the question")
            snap(app, "conversation-hearing")
            XCTAssertTrue(app.staticTexts["MYCROFT"].waitForExistence(timeout: 120), "Mycroft speaks")
            snap(app, "conversation-speaking")
            Thread.sleep(forTimeInterval: 6)
            snap(app, "conversation-speaking-later")
            _ = app.staticTexts["LISTENING"].waitForExistence(timeout: 120)
            snap(app, "conversation-after")
        }
        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))
        snap(app, "conversation-muted")
        end.tap()
        XCTAssertTrue(app.buttons["Talk"].waitForExistence(timeout: 10), "ending it brings the composer back")
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
