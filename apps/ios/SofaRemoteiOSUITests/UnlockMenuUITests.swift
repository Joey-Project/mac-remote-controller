import XCTest

/// Explicit opt-in only: this test can unlock the named, already paired Mac.
final class LiveUnlockUITests: XCTestCase {
    @MainActor
    func testOneRequestAgainstThePairedPhysicalMac() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SOFA_REMOTE_LIVE_UNLOCK_TEST"] == "1",
            let expectedMac = environment["SOFA_REMOTE_LIVE_MAC_NAME"], !expectedMac.isEmpty
        else {
            throw XCTSkip("Requires explicit authorization for the named physical Mac.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.joeyteng.sofaremote.ios")
        app.activate()
        if app.alerts["Connection problem"].exists { app.alerts.buttons["OK"].tap() }
        let menu = element("remote.menu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "Connect the physical phone first.")
        XCTAssertTrue(app.navigationBars[expectedMac].exists, "The connected Mac must match.")
        menu.tap()
        let unlock = element("remote.unlock", in: app)
        XCTAssertTrue(unlock.waitForExistence(timeout: 3))
        XCTAssertTrue(unlock.isEnabled)
        XCTAssertEqual(unlock.label, "Unlock Mac", "The Mac must begin locked.")
        unlock.tap()
        if app.alerts["Connection problem"].waitForExistence(timeout: 12) {
            XCTFail("The paired Mac did not confirm this single unlock request.")
            return
        }
        menu.tap()
        let lock = element("remote.lock", in: app)
        XCTAssertTrue(lock.waitForExistence(timeout: 3))
        XCTAssertTrue(lock.isEnabled)
        XCTAssertFalse(unlock.exists)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

extension SofaRemoteiOSUITests {
    @MainActor
    func testUnlockNeedsExplicitMenuActionAndUsesOnePayloadFreeCommand() throws {
        launchApp(scenario: "unlock-ready")
        defer { terminateApp() }
        XCTAssertTrue(element("touchpad.surface").waitForExistence(timeout: 5))
        XCTAssertEqual(try commands().count, 0)
        element("remote.menu").tap()
        let unlock = element("remote.unlock")
        XCTAssertTrue(unlock.waitForExistence(timeout: 3))
        XCTAssertTrue(unlock.isEnabled)
        unlock.tap()
        let sent = try waitForCommands(count: 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(Set(sent[0].keys), ["name"])
        XCTAssertEqual(sent[0]["name"] as? String, "session.unlock")
        element("remote.menu").tap()
        XCTAssertFalse(element("remote.unlock").isEnabled)
    }

    @MainActor
    func testUnlockWithoutPerDevicePermissionIsDisabled() throws {
        launchApp(scenario: "unlock-denied")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.unlock").waitForExistence(timeout: 3))
        XCTAssertFalse(element("remote.unlock").isEnabled)
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testLegacyCompanionDoesNotOfferUnlock() throws {
        launchApp(scenario: "legacy-companion")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertFalse(element("remote.unlock").exists)
        XCTAssertFalse(element("remote.lock").exists)
        XCTAssertFalse(element("remote.displayOff").exists)
        XCTAssertFalse(element("remote.lockDisplayOff").exists)
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testLockAndUnlockAreMutuallyExclusiveAndSendOnlyExplicitCommands() throws {
        launchApp(scenario: "session-controls")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.lock").waitForExistence(timeout: 3))
        XCTAssertTrue(element("remote.lock").isEnabled)
        XCTAssertFalse(element("remote.unlock").exists)
        element("remote.lock").tap()
        _ = try waitForCommands(count: 1)
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.unlock").waitForExistence(timeout: 3))
        XCTAssertFalse(element("remote.lock").exists)
        XCTAssertTrue(element("remote.unlock").isEnabled)
        element("remote.unlock").tap()
        let sent = try waitForCommands(count: 2)
        XCTAssertEqual(
            sent.compactMap { $0["name"] as? String }, ["session.lock", "session.unlock"])
        XCTAssertTrue(sent.allSatisfy { Set($0.keys) == ["name"] })
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.lock").isEnabled)
        XCTAssertFalse(element("remote.unlock").exists)
    }

    @MainActor
    func testDisplayOffAndWakeAreMutuallyExclusiveWithoutUnlocking() throws {
        launchApp(scenario: "session-controls-locked")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.displayOff").waitForExistence(timeout: 3))
        XCTAssertTrue(element("remote.displayOff").isEnabled)
        XCTAssertFalse(element("remote.displayWake").exists)
        element("remote.displayOff").tap()
        _ = try waitForCommands(count: 1)
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.displayWake").waitForExistence(timeout: 3))
        XCTAssertFalse(element("remote.displayOff").exists)
        XCTAssertTrue(element("remote.displayWake").isEnabled)
        XCTAssertTrue(element("remote.unlock").isEnabled)
        element("remote.displayWake").tap()
        let sent = try waitForCommands(count: 2)
        XCTAssertEqual(sent.compactMap { $0["name"] as? String }, ["display.off", "display.wake"])
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.unlock").isEnabled)
        XCTAssertFalse(element("remote.lock").exists)
    }

    @MainActor
    func testLockAndDisplayOffUsesOneCommandAndUpdatesBothStates() throws {
        launchApp(scenario: "session-controls")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.lockDisplayOff").waitForExistence(timeout: 3))
        element("remote.lockDisplayOff").tap()
        let sent = try waitForCommands(count: 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["name"] as? String, "session.lock-display-off")
        XCTAssertEqual(Set(sent[0].keys), ["name"])
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.unlock").isEnabled)
        XCTAssertTrue(element("remote.displayWake").isEnabled)
        XCTAssertFalse(element("remote.lockDisplayOff").isEnabled)
    }

    @MainActor
    func testUnknownSessionAndDisplayStatesDisableControls() throws {
        launchApp(scenario: "session-controls-unknown")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.lock").waitForExistence(timeout: 3))
        for identifier in ["remote.lock", "remote.displayOff", "remote.lockDisplayOff"] {
            XCTAssertTrue(element(identifier).exists)
            XCTAssertFalse(element(identifier).isEnabled)
        }
        XCTAssertEqual(try commands().count, 0)
    }

    @MainActor
    func testNativeLockDoesNotRequireAccessibility() throws {
        launchApp(scenario: "session-controls-no-accessibility")
        defer { terminateApp() }
        XCTAssertTrue(element("remote.menu").waitForExistence(timeout: 5))
        element("remote.menu").tap()
        XCTAssertTrue(element("remote.lock").waitForExistence(timeout: 3))
        XCTAssertTrue(element("remote.lock").isEnabled)
        element("remote.lock").tap()
        XCTAssertEqual(try waitForCommands(count: 1)[0]["name"] as? String, "session.lock")
    }
}
