import XCTest

final class SettingsUITests: XCTestCase {
    @MainActor
    func testOfflineSettingsSaveImmediatelyAcrossLaunches() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-scenario=disconnected"]
        app.launch()
        defer { app.terminate() }

        let settings = element("remote.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let drag = app.switches.matching(identifier: "gesture.drag").firstMatch
        XCTAssertTrue(drag.waitForExistence(timeout: 3))
        XCTAssertTrue(drag.isEnabled, "Preferences must be editable without a Mac connection.")
        let original = try XCTUnwrap(switchValue(drag))
        drag.switches.firstMatch.tap()
        recordScreen("Offline Settings after changing drag", in: app)
        let changed = original == "1" ? "0" : "1"
        try await waitForValue(changed, of: drag)
        XCTAssertEqual(try commandCount(in: app), 0)

        app.terminate()
        app.launch()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(drag.waitForExistence(timeout: 3))
        XCTAssertEqual(switchValue(drag), changed)
        drag.switches.firstMatch.tap()
        try await waitForValue(original, of: drag)
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 3))
        XCTAssertEqual(try commandCount(in: app), 0)
    }

    @MainActor
    func testConnectionDetailsTransportSwitchReturnsToSetupWithoutInput() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        defer { app.terminate() }

        let details = element("remote.connectionDetails", in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(element("connection.done", in: app).waitForExistence(timeout: 3))
        recordScreen("Connection details before transport switch", in: app)
        XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("connection.transport", in: app).label.contains("Wi-Fi"))
        let transport = element("remote.switchTransport", in: app)
        XCTAssertTrue(transport.isEnabled)
        transport.tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("touchpad.surface", in: app).exists)
        XCTAssertFalse(app.alerts["Connection problem"].exists)
        XCTAssertEqual(try commandCount(in: app), 0)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func switchValue(_ control: XCUIElement) -> String? {
        let value = control.value
        return value as? String ?? (value as? NSNumber)?.stringValue
    }

    @MainActor
    private func waitForValue(_ value: String, of control: XCUIElement) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        // Sample immediately: a slow remote AX query can exhaust the predicate
        // waiter's timeout even when the switch already has the expected value.
        var actual = switchValue(control)
        while actual != value, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            actual = switchValue(control)
        }
        XCTAssertEqual(actual, value, "The switch must change before relaunching the app.")
    }

    @MainActor
    private func recordScreen(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    private func commandCount(in app: XCUIApplication) throws -> Int {
        let diagnostic = element("uitest.commands", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        let data = Data(diagnostic.label.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).count
    }
}
