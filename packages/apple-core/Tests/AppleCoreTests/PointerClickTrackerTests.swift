import XCTest
@testable import AppleCore

final class PointerClickTrackerTests: XCTestCase {
    func testDoubleClickRequiresSameButtonTimeAndProximity() {
        var tracker = PointerClickTracker()
        XCTAssertEqual(
            tracker.register(button: .left, x: 10, y: 10, at: 1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .left, x: 12, y: 12, at: 1.4, doubleClickInterval: 0.5), 2)
        XCTAssertEqual(
            tracker.register(button: .left, x: 12, y: 12, at: 1.5, doubleClickInterval: 0.5), 1)

        XCTAssertEqual(
            tracker.register(button: .left, x: 0, y: 0, at: 2, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .right, x: 0, y: 0, at: 2.1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .right, x: 10, y: 10, at: 2.2, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .right, x: 10, y: 10, at: 3, doubleClickInterval: 0.5), 1)
    }

    func testSessionResetAndInvalidTimingCannotFormDoubleClick() {
        var tracker = PointerClickTracker()
        XCTAssertEqual(
            tracker.register(button: .left, x: 0, y: 0, at: 1, doubleClickInterval: 0.5), 1)
        tracker.reset()
        XCTAssertEqual(
            tracker.register(button: .left, x: 0, y: 0, at: 1.1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .left, x: 0, y: 0, at: 1, doubleClickInterval: 0.5), 1)
        XCTAssertEqual(
            tracker.register(button: .left, x: 0, y: 0, at: 1.2, doubleClickInterval: .nan), 1)

        XCTAssertEqual(
            tracker.register(
                button: .left, x: 0, y: 0, at: 20, doubleClickInterval: 0.5,
                timebase: .client),
            1)
        tracker.reset()
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 0, y: 0, at: 20.1, doubleClickInterval: 0.5,
                timebase: .client),
            1)
    }

    func testClientTapTimeSurvivesTransportDelayWithoutCrossingTimebases() {
        var tracker = PointerClickTracker()
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 10, y: 10, at: 100, doubleClickInterval: 0.5,
                timebase: .client),
            1)
        // These values are from one client's monotonic clock. Server processing
        // delays are deliberately irrelevant to their difference.
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 10, y: 10, at: 100.4, doubleClickInterval: 0.5,
                timebase: .client),
            2)

        XCTAssertEqual(
            tracker.register(
                button: .left, x: 10, y: 10, at: 500, doubleClickInterval: 0.5,
                timebase: .server),
            1)
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 10, y: 10, at: 500.2, doubleClickInterval: 0.5,
                timebase: .server),
            2)
    }

    func testClientClockRollbackStartsNewSingleClickSequence() {
        var tracker = PointerClickTracker()
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 0, y: 0, at: 300, doubleClickInterval: 0.5,
                timebase: .client),
            1)
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 0, y: 0, at: 2, doubleClickInterval: 0.5,
                timebase: .client),
            1)
        XCTAssertEqual(
            tracker.register(
                button: .left, x: 0, y: 0, at: 2.2, doubleClickInterval: 0.5,
                timebase: .client),
            2)
    }

    func testFailedEventEmissionDoesNotCommitClickHistory() throws {
        struct EventCreationFailure: Error {}

        var tracker = PointerClickTracker()
        XCTAssertThrowsError(
            try tracker.emitClick(
                PointerClickRequest(
                    button: .left, x: 0, y: 0, uptime: 10, doubleClickInterval: 0.5),
                posting: { _ in throw EventCreationFailure() }))

        XCTAssertEqual(
            try tracker.emitClick(
                PointerClickRequest(
                    button: .left, x: 0, y: 0, uptime: 10.1, doubleClickInterval: 0.5),
                posting: { XCTAssertEqual($0, 1) }),
            1)
        XCTAssertThrowsError(
            try tracker.emitClick(
                PointerClickRequest(
                    button: .left, x: 0, y: 0, uptime: 10.2, doubleClickInterval: 0.5),
                posting: { _ in throw EventCreationFailure() }))
        XCTAssertEqual(
            try tracker.emitClick(
                PointerClickRequest(
                    button: .left, x: 0, y: 0, uptime: 10.3, doubleClickInterval: 0.5),
                posting: { XCTAssertEqual($0, 2) }),
            2)
    }
}
