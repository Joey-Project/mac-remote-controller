import XCTest

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
        XCTAssertEqual(try commands().count, 0)
    }
}
