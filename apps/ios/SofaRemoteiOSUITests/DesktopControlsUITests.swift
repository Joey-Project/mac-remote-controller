import UIKit
import XCTest

final class DesktopControlsUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!
    private let actions = ["previous-space", "mission-control", "app-expose", "next-space"]

    @MainActor
    func testAllPanelCombinationsPreserveTouchpadAndSendNoCommands() throws {
        launch()
        defer { app.terminate() }
        let pad = element("touchpad.surface")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        let frame = pad.frame
        assertPanels(volume: false, desktop: false)

        togglePanel("panels.volume")
        assertPanels(volume: true, desktop: false)
        togglePanel("panels.desktop")
        assertPanels(volume: true, desktop: true)
        let volume = element("volume.card").frame
        let desktop = element("desktop.card").frame
        XCTAssertGreaterThanOrEqual(desktop.minY, volume.maxY)
        XCTAssertEqual(desktop.minX, volume.minX, accuracy: 2)
        XCTAssertEqual(desktop.width, volume.width, accuracy: 2)
        attachScreen("Both control panels")

        togglePanel("panels.volume")
        assertPanels(volume: false, desktop: true)
        togglePanel("panels.desktop")
        assertPanels(volume: false, desktop: false)
        XCTAssertEqual(pad.frame, frame, "Panels must not resize the touchpad underneath.")
        XCTAssertEqual(app.scrollViews.count, 0)
        XCTAssertTrue(try commands().isEmpty, "Panel visibility is local UI state.")
    }

    @MainActor
    func testPanelSelectionSurvivesSettingsModesAndRelaunch() throws {
        launch()
        defer { app.terminate() }
        XCTAssertTrue(element("remote.panels").waitForExistence(timeout: 5))
        togglePanel("panels.desktop")
        element("mode.keyboard").tap()
        XCTAssertTrue(element("keyboard.text").waitForExistence(timeout: 3))
        assertPanels(volume: false, desktop: true)

        element("remote.menu").tap()
        let settings = element("remote.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        assertPanels(volume: false, desktop: true)
        element("mode.touchpad").tap()
        assertPanels(volume: false, desktop: true)

        app.terminate()
        app.launchArguments.append("--ui-testing-preserve-panels")
        app.launch()
        XCTAssertTrue(element("remote.panels").waitForExistence(timeout: 5))
        assertPanels(volume: false, desktop: true)
        togglePanel("panels.volume")
        assertPanels(volume: true, desktop: true)
        element("remote.panels").tap()
        let hideAll = element("panels.hideAll")
        XCTAssertTrue(hideAll.waitForExistence(timeout: 3))
        hideAll.tap()
        assertPanels(volume: false, desktop: false)
        XCTAssertTrue(try commands().isEmpty)
    }

    @MainActor
    func testDesktopButtonsSendOnlyTheirMatchingSystemActions() throws {
        launch()
        defer { app.terminate() }
        XCTAssertTrue(element("remote.panels").waitForExistence(timeout: 5))
        togglePanel("panels.desktop")
        for action in actions {
            let button = element("desktop.\(action)")
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            button.tap()
        }
        let accepted = try commands()
        XCTAssertEqual(accepted.count, actions.count)
        XCTAssertEqual(
            accepted.compactMap { $0["name"] as? String },
            Array(repeating: "system.shortcut", count: actions.count))
        XCTAssertEqual(accepted.compactMap { $0["shortcut"] as? String }, actions)
    }

    @MainActor
    func testDesktopButtonsRequireCapabilityAndAccessibility() throws {
        for scenario in ["legacy-companion", "permission-denied"] {
            launch(scenario: scenario)
            defer { app.terminate() }
            XCTAssertTrue(element("remote.panels").waitForExistence(timeout: 5))
            togglePanel("panels.desktop")
            for action in actions {
                let button = element("desktop.\(action)")
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                XCTAssertFalse(button.isEnabled)
            }
            XCTAssertTrue(try commands().isEmpty)
        }
    }

    @MainActor
    func testKeyboardRemainsUsableWithBothPanelsVisible() throws {
        launch()
        defer { app.terminate() }
        XCTAssertTrue(element("remote.panels").waitForExistence(timeout: 5))
        togglePanel("panels.volume")
        togglePanel("panels.desktop")
        element("mode.keyboard").tap()
        let field = element("keyboard.text")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        for _ in 0..<3 {
            if field.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(field.isHittable)
        field.tap()
        field.typeText("Panel draft")
        XCTAssertEqual(field.value as? String, "Panel draft")
        XCTAssertTrue(try commands().isEmpty, "Editing a draft must not send it.")
        attachScreen("Keyboard with both panels")
    }

    @MainActor
    private func launch(scenario: String? = nil) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if let scenario { app.launchArguments.append("--ui-testing-scenario=\(scenario)") }
        app.launch()
    }

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func togglePanel(_ identifier: String) {
        element("remote.panels").tap()
        let toggle = element(identifier)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
    }

    @MainActor
    private func assertPanels(volume: Bool, desktop: Bool) {
        for (identifier, visible) in [("volume.card", volume), ("desktop.card", desktop)] {
            let control = element(identifier)
            if visible {
                XCTAssertTrue(control.waitForExistence(timeout: 3), "Missing \(identifier)")
                let frame = control.frame
                let viewport = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
                XCTAssertFalse(frame.isEmpty, "Empty bounds for \(identifier)")
                XCTAssertTrue(
                    viewport.contains(frame), "\(identifier) bounds \(frame) exceed \(viewport)")
                // The container has no action; hit-test its interactive children.
                let children =
                    identifier == "desktop.card"
                    ? actions.map { "desktop.\($0)" } : ["volume.slider"]
                for child in children {
                    XCTAssertTrue(element(child).isHittable, "Control is not hittable: \(child)")
                }
            } else {
                XCTAssertFalse(control.exists, "Unexpected \(identifier)")
            }
        }
    }

    @MainActor
    private func commands() throws -> [[String: Any]] {
        let diagnostic = element("uitest.commands")
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 3))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(diagnostic.label.utf8))
                as? [[String: Any]])
    }

    @MainActor
    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension SofaRemoteiOSUITests {
    @MainActor
    func togglePanel(_ identifier: String) {
        element("remote.panels").tap()
        let control = element(identifier)
        XCTAssertTrue(control.waitForExistence(timeout: 3))
        control.tap()
    }
}
