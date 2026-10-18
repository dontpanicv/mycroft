import XCTest

/// End-to-end runs against the real model. They need a signed-in app (scripts/dev-run.sh hands over the sign-in)
/// and are skipped unless MYCROFT_LIVE=1, because they spend tokens.
final class ConversationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEST_RUNNER_MYCROFT_LIVE"] == "1"
            || ProcessInfo.processInfo.environment["MYCROFT_LIVE"] == "1", "set MYCROFT_LIVE=1 to talk to the real model")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// New thread → message → Sol answers.
    func testAskAndAnswer() throws {
        startThread()
        send("Reply with exactly the word: pineapple")
        let answer = app.staticTexts.matching(identifier: "assistantText").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "no answer from the model")
        XCTAssertTrue(waitForIdle(timeout: 120))
        XCTAssertTrue(answer.label.lowercased().contains("pineapple"), "answer was: \(answer.label)")
        attachScreenshot("answer")
    }

    /// The agent edits its own code, activates it, and the next turn runs the new generation.
    func testSelfModification() throws {
        startThread()
        send("""
            Use your self tools: read extension.js, then add a tool named "coin" that returns "heads" or "tails" at \
            random. Write it to the draft, activate it with a short note, then call coin once and tell me the result.
            """)
        XCTAssertTrue(waitForIdle(timeout: 300), "the self-edit run did not finish")
        attachScreenshot("self-edit")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n").lowercased()
        XCTAssertTrue(texts.contains("self_activate"), "no activation call visible")
        XCTAssertTrue(texts.contains("coin"), "the new tool was not called")
    }

    /// A multi-step run reported in the Dynamic Island while the app is in the background.
    func testLiveActivityInBackground() throws {
        startThread()
        send("""
            Do these one at a time, each as its own tool call: self_status, then self_read SELF.md, then now, \
            then self_read extension.js. After that, answer with one short sentence.
            """)
        _ = app.staticTexts["status.running"].waitForExistence(timeout: 20)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        Thread.sleep(forTimeInterval: 2)
        // Live Activities show in Notification Center too; pull it down from the top-left edge.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6)))
        for second in [2, 6, 10] {
            Thread.sleep(forTimeInterval: second == 2 ? 2 : 4)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "activity-\(second)s"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.activate()
        XCTAssertTrue(waitForIdle(timeout: 240))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6)))
        Thread.sleep(forTimeInterval: 2)
        let done = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        done.name = "island-done"
        done.lifetime = .keepAlways
        add(done)
    }

    /// Settings → Machines → Add machine, then waits while the command (on the clipboard) is run on a computer.
    /// The harness runs it: scripts/e2e-pair.sh reads the Simulator's pasteboard and pipes it to sh.
    func testPairMachine() throws {
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let add = app.buttons["addMachine"]
        for _ in 0..<6 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.staticTexts["installCommand"].waitForExistence(timeout: 20))
        print("INSTALL COMMAND: \(app.staticTexts["installCommand"].label)")
        let paired = app.staticTexts["pairedName"]
        XCTAssertTrue(paired.waitForExistence(timeout: 240), "the machine never paired")
        attachScreenshot("paired")
        print("PAIRED WITH: \(paired.label)")
    }

    /// Uses the paired machine: the agent runs a command there through hands.
    func testRunOnPairedMachine() throws {
        startThread()
        send("Use hands_exec on the paired machine to run `uname -sm && whoami`, then tell me the output in one line.")
        XCTAssertTrue(waitForIdle(timeout: 180))
        attachScreenshot("remote-exec")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        XCTAssertTrue(texts.contains("hands_exec"), "no hands_exec call: \(texts)")
        XCTAssertTrue(texts.contains("Darwin"), "no uname output: \(texts)")
    }

    /// The user's scenario: one prompt, two machines, working together in one turn.
    func testServerOnLinuxClientOnMac() throws {
        startThread()
        send("""
            Start a small web server on the Linux box on port 8080 that serves a page saying hello from linux \
            (busybox httpd is available there), then fetch it from the Mac with curl and tell me whether the two \
            machines can talk. Stop the server when you are done.
            """)
        XCTAssertTrue(waitForIdle(timeout: 300), "the run did not finish")
        attachScreenshot("two-machines")
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        print("TRANSCRIPT:\n\(texts)")
        XCTAssertTrue(texts.contains("hands_job_start") || texts.contains("hands_exec"), "no hands calls")
    }

    private func startThread() {
        let new = app.buttons["newThread"]
        XCTAssertTrue(new.waitForExistence(timeout: 30))
        new.tap()
        XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10) || app.textFields["composer"].waitForExistence(timeout: 1))
    }

    private func send(_ text: String) {
        let composer = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields["composer"]
        composer.tap()
        composer.typeText(text)
        app.buttons["send"].tap()
    }

    private func waitForIdle(timeout: TimeInterval) -> Bool {
        // Wait for the run to start, then to end.
        _ = app.staticTexts["status.running"].waitForExistence(timeout: 20)
        let idle = app.staticTexts["status.idle"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if idle.exists && !app.staticTexts["status.running"].exists { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
