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
        let remaining = state.release([.left]) { _ in
            XCTFail("released button should not retry")
            return true
        }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTimeoutRetainsButtonsUntilReleasePostingSucceeds() {
        var state = HeldInputState()
        let now: TimeInterval = 100
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .right), at: now)
        XCTAssertTrue(state.expiredButtons(ifOlderThan: 8, now: now + 7.9).isEmpty)
        XCTAssertEqual(state.expiredButtons(ifOlderThan: 8, now: now + 8), [.right])
        XCTAssertEqual(state.release([.right]) { _ in false }, [.right])
        XCTAssertEqual(state.buttons, [.right])
        XCTAssertEqual(state.expiredButtons(ifOlderThan: 8, now: now + 9), [.right])
        XCTAssertTrue(state.release([.right]) { _ in true }.isEmpty)
        XCTAssertTrue(state.buttons.isEmpty)
        XCTAssertNil(state.lastUpdate)
    }

    func testPartialReleaseRetainsOnlyButtonsWhosePostFailed() {
        var state = HeldInputState()
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: 10)
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .right), at: 11)

        XCTAssertEqual(
            state.release([.left, .right]) { $0 == .left },
            [.right])
        XCTAssertEqual(state.buttons, [.right])
        XCTAssertEqual(state.lastUpdate, 11)
        XCTAssertTrue(state.release([.right]) { _ in true }.isEmpty)
    }

    func testDragButtonSelectsRightAndPrefersLeftWhenBothAreHeld() {
        var state = HeldInputState()
        XCTAssertNil(state.dragButton)
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .right), at: 1)
        XCTAssertEqual(state.dragButton, .right)
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: 2)
        XCTAssertEqual(state.dragButton, .left)
        _ = state.apply(RemoteCommand(name: .pointerButtonUp, button: .left), at: 3)
        XCTAssertEqual(state.dragButton, .right)
    }

    func testActiveMovementRefreshesTheIdleReleaseDeadline() {
        var state = HeldInputState()
        let start: TimeInterval = 100
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: .left), at: start)
        state.refresh(at: start + 7)
        XCTAssertTrue(state.expiredButtons(ifOlderThan: 8, now: start + 14).isEmpty)
        XCTAssertEqual(state.expiredButtons(ifOlderThan: 8, now: start + 15), [.left])
    }
}
