import XCTest

extension SofaRemoteiOSUITests {
    @MainActor
    private func requestNumericCode(_ code: String, scenario: String = "numeric-pairing") {
        launchApp(scenario: scenario, arguments: ["--pairing-test-code=\(code)"])
        let mac = element("pairing.mac.00000000-0000-4000-8000-000000000042")
        XCTAssertTrue(mac.waitForExistence(timeout: 5))
        mac.tap()
    }

    @MainActor
    private func submitNumericCode(_ code: String) {
        let field = element("pairing.code")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isEnabled)
        field.tap()
        field.typeText(code)
        let submit = element("pairing.submit")
        XCTAssertTrue(submit.isEnabled)
        assertPairingActionsStayAboveKeyboard()
        submit.tap()
    }

    @MainActor
    private func assertPairingActionsStayAboveKeyboard() {
        let keyboard = XCUIApplication().keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        for identifier in ["pairing.submit", "pairing.cancel"] {
            let action = element(identifier)
            XCTAssertTrue(action.isHittable)
            XCTAssertLessThanOrEqual(action.frame.maxY, keyboard.frame.minY)
        }
    }

    @MainActor
    func testNumericPairingSucceedsAndSavedMacReconnectsWithoutAnotherCode() throws {
        let code = String(format: "%04d", UInt32.random(in: 0..<10_000))
        requestNumericCode(code)
        defer { terminateApp() }
        XCTAssertFalse(element("touchpad.surface").exists)
        XCTAssertEqual(try commands().count, 0)
        submitNumericCode(code)
        XCTAssertTrue(element("touchpad.surface").waitForExistence(timeout: 8))
        XCTAssertFalse(element("pairing.code").exists)
        XCTAssertEqual(try commands().count, 0)
        element("remote.connectionDetails").tap()
        element("remote.disconnect").tap()
        let mac = element("pairing.mac.00000000-0000-4000-8000-000000000042")
        XCTAssertTrue(mac.waitForExistence(timeout: 5))
        mac.tap()
        XCTAssertTrue(element("touchpad.surface").waitForExistence(timeout: 5))
        XCTAssertFalse(element("pairing.code").exists)
    }

    @MainActor
    func testWrongNumericCodeCanBeCorrectedWithoutGrantingControl() throws {
        let code = String(format: "%04d", UInt32.random(in: 0..<10_000))
        requestNumericCode(code)
        defer { terminateApp() }
        let wrong = (code.first == "0" ? "1" : "0") + String(code.dropFirst())
        submitNumericCode(wrong)
        XCTAssertTrue(element("pairing.codeError").waitForExistence(timeout: 5))
        XCTAssertEqual(element("pairing.attempts").label, "2 attempts remaining")
        XCTAssertFalse(element("touchpad.surface").exists)
        XCTAssertEqual(try commands().count, 0)
        attachScreenshot("Incorrect pairing code with two attempts remaining")
        submitNumericCode(code)
        XCTAssertTrue(element("touchpad.surface").waitForExistence(timeout: 8))
    }

    @MainActor
    func testThirdIncorrectCodeInvalidatesPairing() throws {
        let code = String(format: "%04d", UInt32.random(in: 0..<10_000))
        requestNumericCode(code)
        defer { terminateApp() }
        let wrong = (code.first == "0" ? "1" : "0") + String(code.dropFirst())
        for remaining in stride(from: 2, through: 1, by: -1) {
            submitNumericCode(wrong)
            let attempts = element("pairing.attempts")
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label == %@",
                    remaining == 1 ? "1 attempt remaining" : "\(remaining) attempts remaining"),
                object: attempts)
            wait(for: [updated], timeout: 5)
        }
        submitNumericCode(wrong)
        let app = XCUIApplication()
        XCTAssertTrue(
            app.alerts.staticTexts[
                "Too many incorrect codes. Wait a minute, then request a new code."
            ].waitForExistence(timeout: 5))
        XCTAssertFalse(element("touchpad.surface").exists)
        XCTAssertEqual(try commands().count, 0)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Unpaired · tap to pair"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCancellingNumericPairingLeavesMacUnpaired() throws {
        requestNumericCode(String(format: "%04d", UInt32.random(in: 0..<10_000)))
        defer { terminateApp() }
        XCTAssertTrue(element("pairing.code").waitForExistence(timeout: 5))
        element("pairing.cancel").tap()
        XCTAssertTrue(
            XCUIApplication().staticTexts["Unpaired · tap to pair"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("pairing.code").exists)
        XCTAssertFalse(element("touchpad.surface").exists)
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testExpiredNumericCodeCannotConnect() throws {
        requestNumericCode(
            String(format: "%04d", UInt32.random(in: 0..<10_000)),
            scenario: "numeric-pairing-expired")
        defer { terminateApp() }
        let app = XCUIApplication()
        XCTAssertTrue(
            app.alerts.staticTexts[
                "This pairing code has expired. Request a new code."
            ].waitForExistence(timeout: 5))
        XCTAssertFalse(element("touchpad.surface").exists)
        XCTAssertEqual(try commands().count, 0)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.staticTexts["Unpaired · tap to pair"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testQRPairingRemainsAnExplicitAlternative() {
        launchApp(scenario: "disconnected")
        defer { terminateApp() }
        let alternatives = element("pairing.alternatives")
        XCTAssertTrue(alternatives.waitForExistence(timeout: 5))
        alternatives.tap()
        XCTAssertTrue(
            XCUIApplication().buttons["Scan pairing QR code"].waitForExistence(timeout: 3))
    }
}
