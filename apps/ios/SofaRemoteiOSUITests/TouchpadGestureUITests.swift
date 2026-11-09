import XCTest

extension SofaRemoteiOSUITests {
    @MainActor
    func testPinchEmitsBalancedMagnificationWithoutScrollOrClick() throws {
        launchApp()
        defer { terminateApp() }
        let pad = element("touchpad.surface")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        pad.pinch(withScale: 1.5, velocity: 2)
        let log = try waitForCommands { commands in
            commands.contains {
                ($0["gesture"] as? [String: Any])?["phase"] as? String == "ended"
            }
        }
        let frames = log.compactMap { $0["gesture"] as? [String: Any] }
        XCTAssertEqual(frames.first?["phase"] as? String, "began")
        XCTAssertEqual(frames.last?["phase"] as? String, "ended")
        let ids = Set(frames.compactMap { $0["id"] as? String })
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0["kind"] as? String == "magnify" })
        XCTAssertTrue(frames.contains { $0["phase"] as? String == "changed" })
        XCTAssertFalse(
            log.contains {
                ["pointer.scroll", "pointer.click", "keyboard.key"].contains(
                    $0["name"] as? String ?? "")
            })
    }

    @MainActor
    func testLegacyCompanionNeverReceivesPhasedPinchOrAccidentalRightClick() throws {
        launchApp(scenario: "legacy-companion")
        defer { terminateApp() }
        let pad = element("touchpad.surface")
        XCTAssertTrue(pad.waitForExistence(timeout: 5))
        pad.pinch(withScale: 1.5, velocity: 2)
        let log = try commands()
        XCTAssertFalse(log.contains { $0["name"] as? String == "gesture.frame" })
        XCTAssertFalse(log.contains { $0["name"] as? String == "pointer.click" })
    }
}
