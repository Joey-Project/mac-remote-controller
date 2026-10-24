import Foundation
import XCTest
@testable import AppleCore

final class HeldInputStateTests: XCTestCase {
    func testHeldButtonsReleaseOnceAndDuplicateTransitionsAreIdempotent() {
        var state = HeldInputState()
        let now: TimeInterval = 100
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: now)
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: now)
        XCTAssertEqual(state.buttons, [.left])
        _ = state.apply(RemoteCommand(name: .pointerButtonUp, button: .left), at: now)
        XCTAssertTrue(state.releaseAll().isEmpty)
    }

    func testDisconnectAndTimeoutReturnEveryHeldButtonForRelease() {
        var state = HeldInputState()
        let now: TimeInterval = 100
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .right), at: now)
        XCTAssertTrue(state.expire(ifOlderThan: 8, now: now + 7.9).isEmpty)
        XCTAssertEqual(state.expire(ifOlderThan: 8, now: now + 8), [.right])
        XCTAssertTrue(state.buttons.isEmpty)

        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: now)
        XCTAssertEqual(state.releaseAll(), [.left])
        XCTAssertTrue(state.releaseAll().isEmpty)
    }

    func testActiveMovementRefreshesTheIdleReleaseDeadline() {
        var state = HeldInputState()
        let start: TimeInterval = 100
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: start)
        state.refresh(at: start + 7)
        XCTAssertTrue(state.expire(ifOlderThan: 8, now: start + 14).isEmpty)
        XCTAssertEqual(state.expire(ifOlderThan: 8, now: start + 15), [.left])
    }
}
