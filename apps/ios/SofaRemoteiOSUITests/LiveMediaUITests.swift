import XCTest

/// Opt-in acceptance against a paired real Mac and the installed browser extension.
final class LiveMediaUITests: XCTestCase {
    @MainActor
    func testLiveChromeSeekReceivesSuccessfulResultsWithoutFalseAlerts() throws {
        guard ProcessInfo.processInfo.environment["SOFA_REMOTE_LIVE_MEDIA_TEST"] == "1" else {
            throw XCTSkip(
                "Requires a paired Mac and an installed Chrome extension with an open video.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        // This flag exposes matched result counts only. It never enables fixtures
        // or changes authentication, discovery, routing, or the command transport.
        app.launchArguments = ["--live-media-test"]
        app.launch()
        let menu = element("remote.menu", in: app)
        if !menu.waitForExistence(timeout: 5) {
            let paired = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Paired"))
                .firstMatch
            XCTAssertTrue(
                paired.waitForExistence(timeout: 10), "Pair this test device with the Mac first.")
            paired.tap()
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        element("mode.keyboard", in: app).tap()
        let picker = element("media.target", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let prefix =
            ProcessInfo.processInfo.environment["SOFA_REMOTE_LIVE_MEDIA_PREFIX"] ?? "Bilibili"
        let target = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", prefix))
            .firstMatch
        XCTAssertTrue(
            target.waitForExistence(timeout: 5), "Open the requested Chrome video before this test."
        )
        target.tap()
        let seek = app.buttons["Seek forward 10 seconds"]
        XCTAssertTrue(seek.waitForExistence(timeout: 5))
        XCTAssertTrue(seek.isEnabled)
        let receipts = element("live.results", in: app)
        for count in 1...3 {
            seek.tap()
            let expected = "\(count):0"
            let predicate = NSPredicate(format: "label == %@", expected)
            let result = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: predicate, object: receipts)], timeout: 5
            )
            XCTAssertEqual(
                result, .completed, "Expected a correlated successful result from the real Mac.")
            XCTAssertFalse(app.alerts["Connection problem"].exists)
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Chrome seek acknowledged by Mac"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
