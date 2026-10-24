import AppleCore
import Foundation
import XCTest

final class HeldInputTerminationTests: XCTestCase {
    func testReleasesAllActiveAndPendingSessionsBeforeAllowingExit() {
        var active = ["active-left": held(.left), "active-right": held(.right)]
        var pending = ["disconnected": held(.left)]
        var posted: [PointerButton] = []
        XCTAssertTrue(
            HeldInputTermination.prepare(active: &active, pending: &pending) { state in
                _ = state.release(Array(state.buttons)) {
                    posted.append($0); return true
                }
            })
        XCTAssertEqual(posted.count, 3)
        XCTAssertTrue(active.values.allSatisfy { $0.buttons.isEmpty })
        XCTAssertTrue(pending.isEmpty)
    }

    func testFailedReleaseBlocksExitAndRetainsRetryStateWithoutSkippingOthers() {
        var active = ["active": held(.left)]
        var pending = ["pending-a": held(.left), "pending-b": held(.right)]
        var attempted = 0
        XCTAssertFalse(
            HeldInputTermination.prepare(active: &active, pending: &pending) { state in
                _ = state.release(Array(state.buttons)) { _ in
                    attempted += 1; return false
                }
            })
        XCTAssertEqual(attempted, 3)
        XCTAssertEqual(active["active"]?.buttons, [.left])
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(
            HeldInputTermination.prepare(active: &active, pending: &pending) { state in
                _ = state.release(Array(state.buttons)) { _ in true }
            })
        XCTAssertTrue(pending.isEmpty)
    }

    func testRepeatedPreparationDoesNotPostDuplicateReleases() {
        var active = ["active": held(.right)]
        var pending: [String: HeldInputState] = [:]
        var posted = 0
        for _ in 0..<2 {
            XCTAssertTrue(
                HeldInputTermination.prepare(active: &active, pending: &pending) { state in
                    _ = state.release(Array(state.buttons)) { _ in
                        posted += 1; return true
                    }
                })
        }
        XCTAssertEqual(posted, 1)
    }

    private func held(_ button: PointerButton) -> HeldInputState {
        var state = HeldInputState()
        _ = state.apply(RemoteCommand(name: .pointerButtonDown, button: button))
        return state
    }
}
