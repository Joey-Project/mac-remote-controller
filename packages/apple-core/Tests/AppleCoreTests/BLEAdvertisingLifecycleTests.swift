import XCTest

@testable import AppleCore

final class BLEAdvertisingLifecycleTests: XCTestCase {
    func testAdvertisingBeginsOnlyAfterSuccessfulCompletion() {
        var lifecycle = BLEAdvertisingLifecycle()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertEqual(lifecycle.completeStart(successfully: true), .started)
        XCTAssertEqual(lifecycle.phase, .advertising)
        XCTAssertFalse(lifecycle.beginStart())
    }

    func testFailedStartAllowsOneBoundedRetry() {
        var lifecycle = BLEAdvertisingLifecycle()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertEqual(lifecycle.completeStart(successfully: false), .retry)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertEqual(lifecycle.completeStart(successfully: false), .failed)
        XCTAssertEqual(lifecycle.phase, .failed)
        XCTAssertFalse(lifecycle.beginStart())
    }

    func testResetIgnoresStaleCompletionAndAllowsFreshStart() {
        var lifecycle = BLEAdvertisingLifecycle()

        XCTAssertTrue(lifecycle.beginStart())
        lifecycle.reset()

        XCTAssertEqual(lifecycle.completeStart(successfully: true), .ignored)
        XCTAssertEqual(lifecycle.phase, .idle)
        XCTAssertTrue(lifecycle.beginStart())
    }
}
