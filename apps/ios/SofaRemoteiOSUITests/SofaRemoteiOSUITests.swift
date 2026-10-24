import XCTest
import UIKit

final class SofaRemoteiOSUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!

    @MainActor
    func testTouchpadUsesDragAndTwoFingerTapCommands() throws {
        launchApp()
        defer { terminateApp() }

        let pad = element("touchpad.surface")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        XCTAssertTrue(pad.isHittable)
        XCTAssertGreaterThanOrEqual(
            pad.frame.height, app.windows.firstMatch.frame.height * 0.6,
            "The default touchpad should occupy most of the portrait display.")
        XCTAssertEqual(app.scrollViews.count, 0, "The default touchpad should fill the screen.")

        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.55))
        let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.40))
        start.press(forDuration: 0.1, thenDragTo: end)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        pad.twoFingerTap()

        let commands = try waitForCommands {
            $0.contains { $0["name"] as? String == "pointer.move" }
                && $0.contains {
                    $0["name"] as? String == "pointer.click"
                        && $0["button"] as? String == "left"
                }
                && $0.contains {
                    $0["name"] as? String == "pointer.click"
                        && $0["button"] as? String == "right"
                }
        }
        XCTAssertGreaterThan(
            commands.filter { $0["name"] as? String == "pointer.move" }.count, 0)
        XCTAssertEqual(
            commands.filter {
                $0["name"] as? String == "pointer.click" && $0["button"] as? String == "left"
            }.count, 1)
        XCTAssertEqual(
            commands.filter {
                $0["name"] as? String == "pointer.click" && $0["button"] as? String == "right"
            }.count, 1)
    }

    @MainActor
    func testPinningVolumePersistsAcrossModesWithoutSendingCommands() throws {
        launchApp()
        defer { terminateApp() }

        let menu = element("remote.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertFalse(element("volume.card").exists)
        XCTAssertEqual(try commands().count, 0)

        menu.tap()
        element("mode.keyboard").tap()
        XCTAssertTrue(element("volume.card").waitForExistence(timeout: 3))
        XCTAssertEqual(try commands().count, 0)
        element("remote.menu").tap()
        element("mode.touchpad").tap()
        XCTAssertFalse(element("volume.card").exists)

        element("remote.menu").tap()
        element("volume.pin").tap()
        let pinnedCard = element("volume.card")
        XCTAssertTrue(pinnedCard.waitForExistence(timeout: 3))
        let touchpadFrame = pinnedCard.frame

        element("remote.menu").tap()
        element("mode.keyboard").tap()
        let keyboardVolume = element("volume.card")
        XCTAssertTrue(keyboardVolume.waitForExistence(timeout: 3))
        XCTAssertTrue(element("keyboard.text").waitForExistence(timeout: 3))
        assertSameFrame(keyboardVolume.frame, touchpadFrame)

        element("remote.menu").tap()
        element("mode.touchpad").tap()
        XCTAssertTrue(element("touchpad.surface").waitForExistence(timeout: 3))
        assertSameFrame(element("volume.card").frame, touchpadFrame)
        XCTAssertEqual(try commands().count, 0, "Changing visible controls must not send input.")

        element("remote.menu").tap()
        element("volume.pin").tap()
        XCTAssertFalse(element("volume.card").exists)
        XCTAssertEqual(try commands().count, 0, "Pinning or unpinning volume is local UI state.")
    }

    @MainActor
    func testGesturePreferencesAreAvailableOnCapableCompanionAndStayLocal() throws {
        launchApp()
        defer { terminateApp() }

        element("remote.menu").tap()
        let gesturePreferences = [
            "gesture.drag", "gesture.shortcuts", "gesture.force", "gesture.haptics"
        ]
        for identifier in gesturePreferences {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 3))
            XCTAssertTrue(element(identifier).isEnabled)
        }
        element("gesture.shortcuts").tap()
        XCTAssertEqual(try commands().count, 0, "Gesture preferences are local settings.")
    }

    @MainActor
    func testLegacyCompanionKeepsNewGesturesDisabled() throws {
        launchApp(scenario: "legacy-companion")
        defer { terminateApp() }

        element("remote.menu").tap()
        let gesturePreferences = [
            "gesture.drag", "gesture.shortcuts", "gesture.force", "gesture.haptics"
        ]
        for identifier in gesturePreferences {
            XCTAssertTrue(element(identifier).waitForExistence(timeout: 3))
            XCTAssertFalse(element(identifier).isEnabled)
        }
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testArrowKeysSendTheirMatchingWireCommands() throws {
        launchApp()
        defer { terminateApp() }

        XCTContext.runActivity(named: "Switch to keyboard mode") { _ in
            chooseKeyboardMode()
        }
        for direction in ["up", "down", "left", "right"] {
            XCTContext.runActivity(named: "Tap the \(direction) arrow") { _ in
                let key = element("key.\(direction)")
                XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing \(direction) key")
                XCTAssertTrue(key.isHittable)
                XCTAssertGreaterThanOrEqual(key.frame.width, 44)
                XCTAssertGreaterThanOrEqual(key.frame.height, 44)
                key.tap()
            }
        }

        let keys = try XCTContext.runActivity(named: "Inspect accepted arrow commands") { _ in
            try waitForCommands(count: 4).compactMap { command -> String? in
                guard command["name"] as? String == "keyboard.key" else { return nil }
                return command["key"] as? String
            }
        }
        XCTAssertEqual(keys, ["up", "down", "left", "right"])
    }

    @MainActor
    func testDraftSurvivesModeChangesAndOnlySendCommitsText() throws {
        launchApp()
        defer { terminateApp() }

        chooseKeyboardMode()
        let textField = element("keyboard.text")
        XCTAssertTrue(textField.waitForExistence(timeout: 3))
        textField.tap()
        textField.typeText("Remote draft 42")
        XCTAssertEqual(try commands().count, 0)

        element("remote.menu").tap()
        element("mode.touchpad").tap()
        element("remote.menu").tap()
        element("mode.keyboard").tap()
        XCTAssertTrue(textField.waitForExistence(timeout: 3))
        XCTAssertEqual(textField.value as? String, "Remote draft 42")
        XCTAssertEqual(try commands().count, 0)

        element("keyboard.send").tap()
        let sent = try waitForCommands(count: 1)
        XCTAssertEqual(sent.first?["name"] as? String, "keyboard.text")
        XCTAssertEqual(sent.first?["text"] as? String, "Remote draft 42")
    }

    @MainActor
    func testDisconnectReturnsToSetupScreen() throws {
        launchApp()
        defer { terminateApp() }

        element("remote.menu").tap()
        element("remote.disconnect").tap()
        XCTAssertTrue(app.staticTexts["Connect to your Mac"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Scan pairing QR code"].exists)
        XCTAssertFalse(element("touchpad.surface").exists)
    }

    @MainActor
    func testBenchmarkRequiresMacProbeCapability() throws {
        launchApp()
        defer { terminateApp() }

        element("remote.menu").tap()
        element("remote.benchmark").tap()

        let runButton = app.buttons["Run benchmark"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 3))
        XCTAssertFalse(runButton.isEnabled)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "does not advertise round-trip probe")
            ).firstMatch.exists)
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testLandscapeControlsRemainVisibleAndInsideTheScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("The app supports landscape orientation on iPad only.")
        }

        launchApp()
        defer { terminateApp() }

        XCUIDevice.shared.orientation = .landscapeLeft
        let windowElement = app.windows.firstMatch
        let orientationDeadline = Date().addingTimeInterval(5)
        while windowElement.frame.width <= windowElement.frame.height,
            Date() < orientationDeadline
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let landscapeWindow = windowElement.frame
        XCTAssertGreaterThan(
            landscapeWindow.width, landscapeWindow.height,
            "The iPad app window should rotate to landscape before layout checks.")

        let pad = element("touchpad.surface")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        assertInsideWindow(pad.frame, window: landscapeWindow)
        XCTAssertTrue(pad.isHittable)

        chooseKeyboardMode()
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<3 {
            let allKeysHittable = ["up", "down", "left", "right"].allSatisfy {
                element("key.\($0)").isHittable
            }
            if allKeysHittable { break }
            XCTAssertTrue(scrollView.exists, "Keyboard controls must be in a scrollable region.")
            scrollView.swipeUp()
        }

        let finalWindow = windowElement.frame
        XCTAssertGreaterThan(finalWindow.width, finalWindow.height)
        for direction in ["up", "down", "left", "right"] {
            let key = element("key.\(direction)")
            XCTAssertTrue(key.waitForExistence(timeout: 3))
            XCTAssertTrue(key.isHittable, "\(direction) key is not hittable in landscape")
            XCTAssertGreaterThanOrEqual(key.frame.width, 44)
            XCTAssertGreaterThanOrEqual(key.frame.height, 44)
            assertInsideWindow(key.frame, window: finalWindow)
        }

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Landscape keyboard controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCUIDevice.shared.orientation = .portrait
    }

}

private extension SofaRemoteiOSUITests {
    @MainActor
    func launchApp(scenario: String? = nil) {
        XCTContext.runActivity(named: "Launch UI test app") { _ in
            continueAfterFailure = false
            XCUIDevice.shared.orientation = .portrait
            app = XCUIApplication()
            app.launchArguments = ["--ui-testing"]
            if let scenario { app.launchArguments.append("--ui-testing-scenario=\(scenario)") }
            app.launch()
        }
    }

    @MainActor
    func terminateApp() {
        app.terminate()
        app = nil
    }

    @MainActor
    func chooseKeyboardMode() {
        let menu = element("remote.menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        element("mode.keyboard").tap()
    }

    @MainActor
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    func diagnosticElement() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "uitest.commands").firstMatch
    }

    @MainActor
    func commands() throws -> [[String: Any]] {
        let diagnostic = diagnosticElement()
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        let json =
            (diagnostic.label.isEmpty ? diagnostic.value as? String : diagnostic.label) ?? "[]"
        let data = Data(json.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @MainActor
    func waitForCommands(count: Int) throws -> [[String: Any]] {
        try waitForCommands { $0.count >= count }
    }

    @MainActor
    func waitForCommands(
        until condition: ([[String: Any]]) -> Bool
    ) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(2)
        var current = try commands()
        while !condition(current) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            current = try commands()
        }
        XCTAssertTrue(condition(current), "Unexpected command log: \(current)")
        return current
    }

    @MainActor
    func assertSameFrame(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 2) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy)
    }

    @MainActor
    func assertInsideWindow(_ frame: CGRect, window: CGRect? = nil) {
        let bounds = window ?? app.windows.firstMatch.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY)
    }
}
