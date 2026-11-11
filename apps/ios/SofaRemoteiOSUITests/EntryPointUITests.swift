import XCTest

final class EntryPointUITests: XCTestCase {
    @MainActor
    func testColdKeyboardURLAndRepeatedWarmModeLinksDoNotSendInput() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.terminate()
        defer { app.terminate() }

        app.open(try XCTUnwrap(URL(string: "sofaremote://remote/keyboard")))
        XCTAssertTrue(element("keyboard.send", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("mode.touchpad", in: app).exists)
        XCTAssertFalse(element("touchpad.surface", in: app).exists)

        app.open(try XCTUnwrap(URL(string: "sofaremote://remote/touchpad")))
        XCTAssertTrue(element("touchpad.surface", in: app).waitForExistence(timeout: 5))
        app.open(try XCTUnwrap(URL(string: "sofaremote://remote/keyboard")))
        XCTAssertTrue(element("keyboard.send", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(try commandCount(in: app), 0)
    }

    @MainActor
    func testOfflineAndUnknownLinksKeepConnectionAndPairingExplicit() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-scenario=disconnected"]
        app.launch()
        defer { app.terminate() }

        app.open(try XCTUnwrap(URL(string: "sofaremote://remote/keyboard")))
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("keyboard.send", in: app).exists)
        XCTAssertFalse(app.alerts["Connection problem"].exists)
        app.open(try XCTUnwrap(URL(string: "sofaremote://remote/unlock")))
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].exists)
        XCTAssertEqual(try commandCount(in: app), 0)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func commandCount(in app: XCUIApplication) throws -> Int {
        let diagnostic = element("uitest.commands", in: app)
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        let data = Data(diagnostic.label.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]).count
    }
}
