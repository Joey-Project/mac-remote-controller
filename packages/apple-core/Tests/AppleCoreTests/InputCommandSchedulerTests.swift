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

    func testGestureReleaseMotionSurvivesSaturatedQueue() {
        var scheduler = InputCommandScheduler(capacity: 3)
        let dragDown = RemoteCommand(name: .pointerButtonDown, button: .left)
        let dragMotion = RemoteCommand(name: .pointerMove, x: 12, y: 4)
        let dragUp = RemoteCommand(name: .pointerButtonUp, button: .left)

        XCTAssertTrue(scheduler.enqueue(dragDown))
        XCTAssertTrue(scheduler.enqueue(dragMotion))
        XCTAssertTrue(scheduler.enqueue(dragUp))
        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 2, y: 1)))

        XCTAssertEqual(scheduler.queuedCommands, [dragDown, dragMotion, dragUp])
    }

    func testSaturatedQueueRejectsReleaseWithoutDroppingDragMotion() {
        var scheduler = InputCommandScheduler(capacity: 3)
        let dragDown = RemoteCommand(name: .pointerButtonDown, button: .left)
        let dragMotion = RemoteCommand(name: .pointerMove, x: 12, y: 4)
        let shortcut = RemoteCommand(name: .systemShortcut, shortcut: .missionControl)
        let dragUp = RemoteCommand(name: .pointerButtonUp, button: .left)

        XCTAssertTrue(scheduler.enqueue(dragDown))
        XCTAssertTrue(scheduler.enqueue(dragMotion))
        XCTAssertTrue(scheduler.enqueue(shortcut))
        XCTAssertFalse(scheduler.enqueue(dragUp))

        XCTAssertEqual(scheduler.queuedCommands, [dragDown, dragMotion, shortcut])
    }

    func testGestureAndShortcutCommandsAreOrderingBarriers() {
        let barriers = [
            RemoteCommand(name: .pointerClick, button: .left),
            RemoteCommand(name: .pointerButtonDown, button: .left),
            RemoteCommand(name: .pointerButtonUp, button: .left),
            RemoteCommand(name: .keyboardText, text: "x"),
            RemoteCommand(name: .keyboardKey, key: .left),
            RemoteCommand(name: .systemShortcut, shortcut: .missionControl)
        ]

        for barrier in barriers {
            var scheduler = InputCommandScheduler(capacity: 2)
            let precedingMotion = RemoteCommand(name: .pointerMove, x: 3, y: 0)
            XCTAssertTrue(scheduler.enqueue(precedingMotion))
            XCTAssertTrue(scheduler.enqueue(barrier))
            XCTAssertFalse(
                scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 2, y: 1)),
                "\(barrier.name.rawValue) must protect preceding pointer motion")
            XCTAssertEqual(scheduler.queuedCommands, [precedingMotion, barrier])
        }
    }

    func testEveryMediaActionIsAnOrderingBarrier() {
        let requests = [
            MediaRequest(targetID: "iina:1", action: .playPause),
            MediaRequest(targetID: "iina:1", action: .seek, value: 5),
            MediaRequest(targetID: "iina:1", action: .next),
            MediaRequest(targetID: "iina:1", action: .previous),
            MediaRequest(targetID: "iina:1", action: .setVolume, value: 0.5)
        ]

        for request in requests {
            var scheduler = InputCommandScheduler(capacity: 2)
            let precedingMotion = RemoteCommand(name: .pointerMove, x: 3, y: 0)
            let mediaCommand = RemoteCommand(name: .mediaControl, mediaRequest: request)
            XCTAssertTrue(scheduler.enqueue(precedingMotion))
            XCTAssertTrue(scheduler.enqueue(mediaCommand))
            XCTAssertFalse(
                scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 2, y: 1)),
                "\(request.action) must protect preceding pointer motion")
            XCTAssertEqual(scheduler.queuedCommands, [precedingMotion, mediaCommand])
        }
    }

    func testSaturatedBarrierQueueDropsOnlyBestEffortPointerDeltas() {
        var scheduler = InputCommandScheduler(capacity: 3)
        let queued = [
            RemoteCommand(name: .pointerMove, x: 30, y: 0),
            RemoteCommand(name: .pointerClick, button: .left),
            RemoteCommand(name: .keyboardKey, key: .left)
        ]
        for command in queued { XCTAssertTrue(scheduler.enqueue(command)) }

        let pointerMove = RemoteCommand(name: .pointerMove, x: 5, y: 0)
        let pointerScroll = RemoteCommand(name: .pointerScroll, x: 0, y: 4)
        XCTAssertTrue(InputCommandScheduler.isBestEffortPointerDelta(pointerMove))
        XCTAssertTrue(InputCommandScheduler.isBestEffortPointerDelta(pointerScroll))
        XCTAssertFalse(scheduler.enqueue(pointerMove))
        XCTAssertFalse(scheduler.enqueue(pointerScroll))

        let discreteCommands = [
            RemoteCommand(name: .pointerClick, button: .right),
            RemoteCommand(name: .keyboardKey, key: .returnKey),
            RemoteCommand(name: .keyboardText, text: "submit"),
            RemoteCommand(name: .systemVolumeSet, value: 0.5)
        ]
        for command in discreteCommands {
            XCTAssertFalse(InputCommandScheduler.isBestEffortPointerDelta(command))
            XCTAssertFalse(scheduler.enqueue(command))
        }
        XCTAssertEqual(scheduler.queuedCommands, queued)
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

    func testAcknowledgementWindowDrainsQueuedBarriersInOrder() {
        var scheduler = InputCommandScheduler(capacity: 8)
        var inFlight: [RemoteCommand] = []
        let commands = (0..<16).map { index in
            RemoteCommand(name: .keyboardKey, key: index.isMultiple(of: 2) ? .left : .right)
        }

        for command in commands {
            XCTAssertTrue(scheduler.enqueue(command))
            flushAvailableCommands(from: &scheduler, into: &inFlight)
        }

        XCTAssertEqual(inFlight, Array(commands.prefix(8)))
        XCTAssertEqual(scheduler.queuedCommands, Array(commands.suffix(8)))

        for expected in commands.suffix(8) {
            inFlight.removeFirst()
            flushAvailableCommands(from: &scheduler, into: &inFlight)
            XCTAssertEqual(inFlight.count, 8)
            XCTAssertEqual(inFlight.last, expected)
        }
    }

    private func flushAvailableCommands(
        from scheduler: inout InputCommandScheduler, into inFlight: inout [RemoteCommand]
    ) {
        let available = max(0, 8 - inFlight.count)
        inFlight += scheduler.dequeue(maximumCount: available)
    }
}
