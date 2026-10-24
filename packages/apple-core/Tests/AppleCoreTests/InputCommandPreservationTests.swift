import AppleCore
import XCTest

final class InputCommandPreservationTests: XCTestCase {
    func testFullQueueRejectsPreservedMotionWithoutReplacingEarlierChunks() {
        var scheduler = InputCommandScheduler(capacity: 2)
        let first = RemoteCommand(name: .pointerMove, x: 500, y: 0)
        let second = RemoteCommand(name: .pointerMove, x: 300, y: 0)
        XCTAssertTrue(scheduler.enqueue(first, preservingMotion: true))
        XCTAssertTrue(scheduler.enqueue(second, preservingMotion: true))
        XCTAssertFalse(
            scheduler.enqueue(
                RemoteCommand(name: .pointerMove, x: 400, y: 0), preservingMotion: true))
        XCTAssertEqual(scheduler.queuedCommands, [first, second])
    }

    func testOrdinaryOverflowCannotDiscardProtectedDragChunks() {
        var scheduler = InputCommandScheduler(capacity: 2)
        let first = RemoteCommand(name: .pointerMove, x: 500, y: 0)
        let second = RemoteCommand(name: .pointerMove, x: 500, y: 0)
        XCTAssertTrue(scheduler.enqueue(first, preservingMotion: true))
        XCTAssertTrue(scheduler.enqueue(second, preservingMotion: true))
        XCTAssertFalse(scheduler.enqueue(RemoteCommand(name: .systemVolumeSet, value: 0)))
        XCTAssertEqual(scheduler.queuedCommands, [first, second])
        XCTAssertEqual(scheduler.dequeue(maximumCount: 1), [first])
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerScroll, x: 0, y: 30)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 25, y: 0)))
        XCTAssertEqual(
            scheduler.queuedCommands, [second, RemoteCommand(name: .pointerMove, x: 25, y: 0)])
    }

    func testResetAndDequeueRetireProtection() {
        var scheduler = InputCommandScheduler(capacity: 1)
        XCTAssertTrue(
            scheduler.enqueue(
                RemoteCommand(name: .pointerMove, x: 500, y: 0), preservingMotion: true))
        _ = scheduler.dequeue(maximumCount: 1)
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerScroll, x: 0, y: 50)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 1, y: 0)))
        scheduler.reset()
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerScroll, x: 0, y: 50)))
        XCTAssertTrue(scheduler.enqueue(RemoteCommand(name: .pointerMove, x: 2, y: 0)))
    }
}
