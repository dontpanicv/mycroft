import XCTest

final class ProbeTests: XCTestCase {
    private func launch(seconds: Int = 120, reportsProgress: Bool? = nil) -> XCUIApplication {
        XCUIDevice.shared.press(.home)
        let app = XCUIApplication()
        app.launchEnvironment["SPIKE_SECONDS"] = String(seconds)
        if let reportsProgress {
            app.launchEnvironment["SPIKE_REPORTS_PROGRESS"] = reportsProgress ? "true" : "false"
        }
        app.launch()
        XCTAssertTrue(app.buttons["continuedFail"].waitForExistence(timeout: 15))
        return app
    }

    private func observe(_ seconds: TimeInterval) {
        let done = expectation(description: "Observation window")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    func testContinuedFailAdmission() {
        let app = launch()
        app.buttons["continuedFail"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(45)
    }

    func testContinuedQueueAdmission() {
        let app = launch()
        app.buttons["continuedQueue"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(45)
    }

    func testLongRunningIntent() {
        let app = launch()
        app.buttons["longIntent"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(90)
        app.activate()
        attach(app)
    }

    func testTenMinuteLongRunningIntentOnDevice() {
        executionTimeAllowance = 900
        let app = launch(seconds: 600)
        app.buttons["longIntent"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(660)
        attach(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    func testLongRunningIntentWithoutProgressOnDevice() {
        let app = launch(reportsProgress: false)
        app.buttons["longIntent"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(90)
        attach(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    func testReloadWhileBackgroundedOnDevice() {
        let app = launch()
        app.buttons["longIntent"].tap()
        XCUIDevice.shared.press(.home)
        observe(140)
        attach(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    func testTenMinuteContinuedProcessingOnDevice() {
        executionTimeAllowance = 900
        let app = launch(seconds: 600)
        app.buttons["continuedFail"].tap()
        observe(10)
        attach(app)
        XCUIDevice.shared.press(.home)
        observe(660)
        attach(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    func testForegroundReloadControl() {
        let app = launch(seconds: 12)
        app.buttons["control"].tap()
        observe(16)
        app.swipeUp()
        XCTAssertEqual(app.staticTexts["status"].label, "work_completed")
        attach(app)
    }

    func testProcessRecovery() {
        var app = launch()
        app.buttons["control"].tap()
        observe(8)
        app.terminate()
        app = launch(seconds: 12)
        app.buttons["resume"].tap()
        observe(10)
        app.swipeUp()
        XCTAssertEqual(app.staticTexts["status"].label, "work_completed")
        attach(app)
    }

    func testSystemShortcutLongRunning() {
        runShortcut(icon: "arrow.triangle.2.circlepath", observation: 130)
    }

    func testSystemShortcutNoProgress() {
        runShortcut(icon: "pause.circle", observation: 130)
    }

    func testSystemShortcutPlainControl() {
        runShortcut(icon: "circle.dashed", observation: 130)
    }

    func testSystemShortcutTenMinutes() {
        executionTimeAllowance = 900
        runShortcut(icon: "hourglass", observation: 660)
    }

    private func runShortcut(icon: String, observation: TimeInterval) {
        // XCTest installs the current app build on launch, not when launching system Shortcuts.
        _ = launch()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.launch()
        observe(4)
        let welcome = shortcuts.buttons["Continue"]
        if welcome.exists { welcome.tap(); observe(2) }
        if shortcuts.buttons["BackButton"].exists { shortcuts.buttons["BackButton"].tap(); observe(1) }
        shortcuts.buttons["Agent Background Spike"].tap()
        observe(1)
        shortcuts.buttons[icon].tap()
        observe(10)
        print("SHORTCUTS_TREE\n" + shortcuts.debugDescription)
        attach(shortcuts)
        if shortcuts.alerts.firstMatch.exists { return }
        XCUIDevice.shared.press(.home)
        observe(observation)
        attach(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
    }

    private func attach(_ app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.lifetime = .keepAlways
        add(tree)
    }
}
