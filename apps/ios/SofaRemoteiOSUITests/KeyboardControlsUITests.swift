import XCTest
import UIKit

final class KeyboardControlsUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!

    @MainActor
    func testNavigationAndEditingButtonsSendOneShotCommands() throws {
        launchApp()
        defer { terminateApp() }
        chooseKeyboardMode()
        let actions = [
            ("key.tab", "keyboard.key", "key", "tab"),
            (
                "keyboard.shortcut.previous-field", "keyboard.shortcut", "keyboardShortcut",
                "previous-field"
            ),
            ("key.forward-delete", "keyboard.key", "key", "forward-delete"),
            ("key.home", "keyboard.key", "key", "home"),
            ("key.end", "keyboard.key", "key", "end"),
            ("key.page-up", "keyboard.key", "key", "page-up"),
            ("key.page-down", "keyboard.key", "key", "page-down"),
            ("keyboard.shortcut.copy", "keyboard.shortcut", "keyboardShortcut", "copy"),
            ("keyboard.shortcut.cut", "keyboard.shortcut", "keyboardShortcut", "cut"),
            ("keyboard.shortcut.paste", "keyboard.shortcut", "keyboardShortcut", "paste"),
            ("keyboard.shortcut.select-all", "keyboard.shortcut", "keyboardShortcut", "select-all"),
            ("keyboard.shortcut.undo", "keyboard.shortcut", "keyboardShortcut", "undo"),
            ("keyboard.shortcut.redo", "keyboard.shortcut", "keyboardShortcut", "redo"),
            ("keyboard.shortcut.find", "keyboard.shortcut", "keyboardShortcut", "find")
        ]
        for (identifier, _, _, _) in actions {
            let button = scrollToKeyboardControl(identifier)
            XCTAssertTrue(button.isEnabled)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
        }
        let sent = try waitForCommands(count: actions.count)
        XCTAssertEqual(sent.count, actions.count)
        for (command, action) in zip(sent, actions) {
            XCTAssertEqual(command["name"] as? String, action.1)
            XCTAssertEqual(command[action.2] as? String, action.3)
            XCTAssertEqual(Set(command.keys), ["name", action.2])
        }
        attachScreenshot("Mac editing shortcuts")
    }

    @MainActor
    func testLegacyKeyboardKeepsBasicKeysWhileNewControlsAreDisabled() throws {
        launchApp(scenario: "legacy-companion")
        defer { terminateApp() }
        chooseKeyboardMode()
        element("key.return").tap()
        XCTAssertEqual(try waitForCommands(count: 1).first?["key"] as? String, "return")
        XCTAssertTrue(element("keyboard.updateRequired").exists)
        XCTAssertFalse(scrollToKeyboardControl("key.tab").isEnabled)
        XCTAssertFalse(scrollToKeyboardControl("keyboard.shortcut.copy").isEnabled)
        XCTAssertEqual(try commands().count, 1)
    }

    @MainActor
    private func scrollToKeyboardControl(_ identifier: String) -> XCUIElement {
        let control = element(identifier)
        for _ in 0..<10 {
            let viewport = app.scrollViews.firstMatch
            if control.exists {
                if control.isHittable { return control }
                let frame = control.frame
                if !control.isEnabled && !frame.isEmpty && viewport.frame.contains(frame) {
                    return control
                }
                if frame.minY < viewport.frame.minY {
                    viewport.swipeDown()
                    continue
                }
            }
            viewport.swipeUp()
        }
        XCTAssertTrue(
            control.isHittable, "Keyboard control must stay reachable by scrolling: \(identifier)")
        return control
    }

    @MainActor
    private func launchApp(scenario: String? = nil) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if let scenario { app.launchArguments.append("--ui-testing-scenario=\(scenario)") }
        app.launch()
    }

    @MainActor private func terminateApp() { app.terminate() }
    @MainActor private func chooseKeyboardMode() {
        XCTAssertTrue(element("mode.keyboard").waitForExistence(timeout: 5))
        element("mode.keyboard").tap()
    }
    @MainActor private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @MainActor private func commands() throws -> [[String: Any]] {
        let diagnostic = element("uitest.commands")
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        let json =
            (diagnostic.label.isEmpty ? diagnostic.value as? String : diagnostic.label) ?? "[]"
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    }
    @MainActor private func waitForCommands(count: Int) throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(3)
        var result = try commands()
        while result.count < count && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            result = try commands()
        }
        XCTAssertEqual(result.count, count)
        return result
    }
    @MainActor private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
