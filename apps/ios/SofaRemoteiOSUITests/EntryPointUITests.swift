import XCTest
import UIKit

final class EntryPointUITests: XCTestCase {
    @MainActor
    func testNativeControlCentreButtonsOpenTheirModesWithoutSendingInput() throws {
        guard ProcessInfo.processInfo.environment["SOFA_REMOTE_NATIVE_CONTROLS_UI_TEST"] == "1"
        else {
            throw XCTSkip("Native system UI acceptance is opt-in; it customizes Control Centre.")
        }
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Native controls require iOS 18 or newer.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        defer { app.terminate() }
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        for (title, identifier, label, destination) in [
            (
                "Sofa Remote Keyboard", "com.joeyteng.sofaremote.keyboard", "Keyboard",
                "keyboard.send"
            ),
            (
                "Sofa Remote Touchpad", "com.joeyteng.sofaremote.touchpad", "Touchpad",
                "touchpad.surface"
            )
        ] {
            XCUIDevice.shared.press(.home)
            openControlCentre(board)
            try addControl(title, in: board)
            XCUIDevice.shared.press(.home)
            openControlCentre(board)
            let controls = board.buttons.matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@", identifier, label))
            XCTAssertTrue(
                controls.firstMatch.waitForExistence(timeout: 30),
                "The control must render before tapping; its placeholder cannot run an intent.")
            recordScreen("Native \(label) control", in: board)
            try XCTUnwrap(controls.allElementsBoundByIndex.last).tap()
            XCTAssertTrue(element(destination, in: app).waitForExistence(timeout: 10))
            recordScreen("\(label) opened by Control Centre", in: app)
            XCTAssertEqual(try commandCount(in: app), 0)
        }
    }

    @MainActor
    private func addControl(_ title: String, in board: XCUIApplication) throws {
        if !board.searchFields.firstMatch.exists {
            let edit = board.buttons["Add Controls"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let add = board.buttons["Add a Control"].firstMatch
            if add.waitForExistence(timeout: 3) { add.tap() }
        }
        let search = board.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if search.buttons["Clear text"].exists { search.buttons["Clear text"].tap() }
        search.typeText(title)
        let typingTip = board.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Speed up your typing'")
        ).firstMatch
        if typingTip.exists && board.buttons["Continue"].exists {
            board.buttons["Continue"].tap()
        }
        let choices = board.icons.matching(identifier: title)
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 10))
        try XCTUnwrap(choices.allElementsBoundByIndex.last).tap()
    }

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
    private func openControlCentre(_ board: XCUIApplication) {
        let top = UIDevice.current.userInterfaceIdiom == .pad ? 0.01 : 0.04
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: top))
            .press(
                forDuration: 0.1,
                thenDragTo: board.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.90, dy: 0.60)))
    }

    @MainActor
    private func recordScreen(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
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
