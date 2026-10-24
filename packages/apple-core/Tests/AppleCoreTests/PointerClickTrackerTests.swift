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
    }
}
