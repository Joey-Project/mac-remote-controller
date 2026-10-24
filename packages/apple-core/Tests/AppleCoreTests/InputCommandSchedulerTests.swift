import AppleCore
import XCTest

final class InputCommandSchedulerTests: XCTestCase {
    func testAdjacentMotionCoalescesWithoutCrossingClickBarrier() {
        var scheduler = InputCommandScheduler()

        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 12, y: -4)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 8, y: 9)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .left)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 3, y: 2)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .pointerMove, x: 20, y: 5),
                RemoteCommand(name: .pointerClick, button: .left),
                RemoteCommand(name: .pointerMove, x: 3, y: 2)
            ])
    }

    func testBackpressureDropsOldMotionButRetainsBarriersAndNewestDelta() {
        var scheduler = InputCommandScheduler(capacity: 3)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 10, y: 0)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .keyboardKey, key: .left)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerScroll, x: 0, y: 5)))

        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 7, y: 2)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .pointerMove, x: 10, y: 0),
                RemoteCommand(name: .keyboardKey, key: .left),
                RemoteCommand(name: .pointerMove, x: 7, y: 2)
            ])
    }

    func testOverflowAfterClickNeverDropsMotionThatPositionsTheClick() {
        var scheduler = InputCommandScheduler(capacity: 3)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 30, y: 0)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .left)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerScroll, x: 0, y: 5)))

        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 9, y: 0)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .pointerMove, x: 30, y: 0),
                RemoteCommand(name: .pointerClick, button: .left),
                RemoteCommand(name: .pointerMove, x: 9, y: 0)
            ])
    }

    func testFullQueueRejectsNewBarrierWithoutDroppingItsPriorMotion() {
        var scheduler = InputCommandScheduler(capacity: 3)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 30, y: 0)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .left)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 5, y: 0)))

        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .right)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .pointerMove, x: 30, y: 0),
                RemoteCommand(name: .pointerClick, button: .left),
                RemoteCommand(name: .pointerMove, x: 5, y: 0)
            ])
    }

    func testOppositeDeltasCancelAndOverflowSplitsAtWireCoordinateLimit() {
        var scheduler = InputCommandScheduler()
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 500, y: 0)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: -500, y: 0)))
        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [RemoteCommand(name: .pointerMove, x: 0, y: 0)])

        scheduler = InputCommandScheduler()
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 500, y: 0)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 500, y: 0)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .pointerMove, x: 500, y: 0),
                RemoteCommand(name: .pointerMove, x: 500, y: 0)
            ])
    }

    func testSchedulerRejectsInvalidWireCommands() {
        var scheduler = InputCommandScheduler()

        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 501, y: 0)))
        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .systemVolumeSet, value: 2)))
        XCTAssertTrue(scheduler.queuedCommands.isEmpty)
    }

    func testAbsoluteVolumeKeepsLatestValueWithoutCrossingBarrier() {
        var scheduler = InputCommandScheduler()
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .systemVolumeSet, value: 0.2)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .right)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .systemVolumeSet, value: 0.8)))

        XCTAssertEqual(
            scheduler.dequeue(maximumCount: 8),
            [
                RemoteCommand(name: .systemVolumeSet, value: 0.2),
                RemoteCommand(name: .pointerClick, button: .right),
                RemoteCommand(name: .systemVolumeSet, value: 0.8)
            ])
    }

    func testResetDiscardsQueuedCommandsAndCapacityRejectsOnlyWhenNoMotionCanBeEvicted() {
        var scheduler = InputCommandScheduler(capacity: 2)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerClick, button: .left)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .keyboardKey, key: .returnKey)))
        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .keyboardKey, key: .escape)))

        scheduler.reset()
        XCTAssertTrue(scheduler.queuedCommands.isEmpty)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .keyboardKey, key: .escape)))
    }
}
