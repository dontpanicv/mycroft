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
