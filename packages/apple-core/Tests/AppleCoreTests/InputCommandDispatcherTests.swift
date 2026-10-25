import AppleCore
import XCTest

final class InputCommandDispatcherTests: XCTestCase {
    private let frame = Duration.nanoseconds(16_666_667)
    private let move = RemoteCommand(name: .pointerMove, x: 1, y: 2)

    func testFirstMotionAndMotionAfterIdleDispatchImmediately() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: start), [move])
        XCTAssertNil(dispatcher.flushDelay(at: start, maximumCount: 8))
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 8, at: start.advanced(by: .seconds(1))), [move])
    }

    func testSixtyHzInputDoesNotSkipEveryOtherFrame() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        for sample in 0..<120 {
            let now = start.advanced(by: frame * sample)
            XCTAssertTrue(dispatcher.enqueue(move))
            // The touch callback may precede a timer callback at the same deadline.
            XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: now), [move])
            XCTAssertTrue(dispatcher.dequeue(maximumCount: 8, at: now).isEmpty)
        }
    }

    func testFasterSamplesCoalesceWithoutRestartingTheDeadline() {
        var dispatcher = InputCommandDispatcher(interval: .milliseconds(16))
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: start), [move])
        for milliseconds in [4, 8, 12] {
            let now = start.advanced(by: .milliseconds(milliseconds))
            XCTAssertTrue(dispatcher.enqueue(move))
            XCTAssertTrue(dispatcher.dequeue(maximumCount: 8, at: now).isEmpty)
            XCTAssertEqual(
                dispatcher.flushDelay(at: now, maximumCount: 8),
                .milliseconds(16 - milliseconds))
        }
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 8, at: start.advanced(by: .milliseconds(16))),
            [RemoteCommand(name: .pointerMove, x: 3, y: 6)])
    }

    func testAcknowledgementsCannotSendContinuousInputBeforeTheDeadline() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: start), [move])
        XCTAssertTrue(dispatcher.enqueue(move))
        for milliseconds in [1, 3, 7, 12, 16] {
            XCTAssertTrue(
                dispatcher.dequeue(
                    maximumCount: 8, at: start.advanced(by: .milliseconds(milliseconds))
                ).isEmpty)
        }
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 8, at: start.advanced(by: frame)), [move])
    }

    func testBackpressureUsesNoTimerAndResumesAsSoonAsCreditReturns() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertNil(dispatcher.flushDelay(at: start, maximumCount: 0))
        XCTAssertTrue(dispatcher.dequeue(maximumCount: 0, at: start).isEmpty)
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 1, at: start.advanced(by: .milliseconds(30))), [move])
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(
            dispatcher.flushDelay(at: start.advanced(by: .milliseconds(31)), maximumCount: 1),
            frame - .milliseconds(1))
    }

    func testLateTimerDoesNotTriggerCatchUpBursts() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        _ = dispatcher.dequeue(maximumCount: 8, at: start)
        XCTAssertTrue(dispatcher.enqueue(move))
        let late = start.advanced(by: .milliseconds(100))
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: late), [move])
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(dispatcher.flushDelay(at: late, maximumCount: 8), frame)
        XCTAssertTrue(dispatcher.dequeue(maximumCount: 8, at: late).isEmpty)
    }

    func testDiscreteActionsFlushPrecedingMotionWithoutReordering() {
        let barriers = [
            RemoteCommand(name: .pointerClick, button: .left),
            RemoteCommand(name: .pointerButtonDown, button: .left),
            RemoteCommand(name: .pointerButtonUp, button: .left),
            RemoteCommand(name: .keyboardKey, key: .escape),
            RemoteCommand(name: .keyboardText, text: "x"),
            RemoteCommand(name: .systemShortcut, shortcut: .missionControl),
            RemoteCommand(
                name: .mediaControl,
                mediaRequest: MediaRequest(targetID: "iina:1", action: .playPause))
        ]
        let start = ContinuousClock.now
        for barrier in barriers {
            var dispatcher = InputCommandDispatcher()
            XCTAssertTrue(dispatcher.enqueue(move))
            _ = dispatcher.dequeue(maximumCount: 8, at: start)
            XCTAssertTrue(dispatcher.enqueue(move, preservingMotion: true))
            XCTAssertTrue(dispatcher.enqueue(barrier))
            XCTAssertEqual(dispatcher.dequeue(maximumCount: 1, at: start), [move])
            XCTAssertEqual(dispatcher.dequeue(maximumCount: 1, at: start), [barrier])
        }
    }

    func testVolumeStillCoalescesAndResetClearsThePacingDeadline() {
        var dispatcher = InputCommandDispatcher()
        let start = ContinuousClock.now
        XCTAssertTrue(dispatcher.enqueue(move))
        _ = dispatcher.dequeue(maximumCount: 8, at: start)
        for value in [0.2, 0.4, 0.6] {
            XCTAssertTrue(dispatcher.enqueue(RemoteCommand(name: .systemVolumeSet, value: value)))
        }
        XCTAssertTrue(dispatcher.dequeue(maximumCount: 8, at: start).isEmpty)
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 8, at: start.advanced(by: frame)),
            [RemoteCommand(name: .systemVolumeSet, value: 0.6)])
        dispatcher.reset()
        XCTAssertTrue(dispatcher.queuedCommands.isEmpty)
        XCTAssertTrue(dispatcher.enqueue(move))
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: start), [move])
    }

    @MainActor
    func testAcknowledgedDragBeginsImmediatelyAndReleaseFlushesTheLastDelta() throws {
        var dispatcher = InputCommandDispatcher()
        let coordinator = LocalPointerDragCoordinator()
        let start = ContinuousClock.now
        let drag = try XCTUnwrap(
            coordinator.begin(trackResults: true) { dispatcher.enqueue($0) })
        let down = dispatcher.dequeue(maximumCount: 8, at: start)
        XCTAssertEqual(down.map(\.name), [.pointerButtonDown])
        coordinator.registerDispatchedCommand(try XCTUnwrap(down.first), requestID: "down")
        XCTAssertTrue(coordinator.move(drag, x: 1, y: 2) { dispatcher.enqueue($0) })
        XCTAssertTrue(dispatcher.queuedCommands.isEmpty)
        _ = coordinator.acceptResult(requestID: "down", succeeded: true)
        coordinator.resume { dispatcher.enqueue($0, preservingMotion: true) }
        XCTAssertEqual(dispatcher.dequeue(maximumCount: 8, at: start), [move])
        XCTAssertTrue(
            coordinator.move(drag, x: 1, y: 2) {
                dispatcher.enqueue($0, preservingMotion: true)
            })
        XCTAssertTrue(dispatcher.dequeue(maximumCount: 8, at: start).isEmpty)
        coordinator.end(drag) { dispatcher.enqueue($0, preservingMotion: true) }
        XCTAssertEqual(
            dispatcher.dequeue(maximumCount: 8, at: start),
            [move, RemoteCommand(name: .pointerButtonUp, button: .left)])
    }
}
