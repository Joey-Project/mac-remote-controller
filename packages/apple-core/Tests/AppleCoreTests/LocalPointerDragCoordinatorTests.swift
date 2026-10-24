import AppleCore
import Foundation
import XCTest

@MainActor
final class LocalPointerDragCoordinatorTests: XCTestCase {
    func testQuickDragReplaysBufferedMotionBeforeReleaseAndLaterShortcut() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        XCTAssertTrue(harness.move(id, x: 300, y: -20))
        XCTAssertTrue(harness.move(id, x: 400, y: 30))
        harness.end(id)
        let shortcut = RemoteCommand(name: .systemShortcut, shortcut: .missionControl)
        XCTAssertEqual(harness.coordinator.deferCommandIfNeeded(shortcut), true)
        XCTAssertEqual(harness.sent.map(\.name), [.pointerButtonDown])
        XCTAssertNil(harness.begin())

        XCTAssertEqual(
            harness.coordinator.acceptResult(requestID: "request-1", succeeded: true),
            .startAccepted(gestureID: id.uuidString))
        harness.resume()
        XCTAssertEqual(
            harness.sent.map(\.name),
            [.pointerButtonDown, .pointerMove, .pointerMove, .pointerButtonUp, .systemShortcut])
        XCTAssertEqual(
            harness.sent.filter { $0.name == .pointerMove }.compactMap(\.x).reduce(0, +), 700)
        XCTAssertEqual(
            harness.sent.filter { $0.name == .pointerMove }.compactMap(\.y).reduce(0, +), 10)
        XCTAssertFalse(harness.move(id, x: 9, y: 9))
    }

    func testAcceptedActiveDragFlushesBufferAndContinuesMoving() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        XCTAssertTrue(harness.move(id, x: 20, y: 2))
        _ = harness.coordinator.acceptResult(requestID: "request-1", succeeded: true)
        harness.resume()
        XCTAssertTrue(harness.move(id, x: 3, y: 4))
        harness.end(id)
        XCTAssertEqual(
            harness.sent.map(\.name),
            [.pointerButtonDown, .pointerMove, .pointerMove, .pointerButtonUp])
        XCTAssertEqual(harness.sent[1].x, 20)
        XCTAssertEqual(harness.sent[2].x, 3)
    }

    func testRejectedStartDiscardsMotionAndReleaseButRetainsLaterInput() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        _ = harness.move(id, x: 30, y: 40)
        harness.end(id)
        let key = RemoteCommand(name: .keyboardKey, key: .escape)
        XCTAssertEqual(harness.coordinator.deferCommandIfNeeded(key), true)
        XCTAssertEqual(
            harness.coordinator.acceptResult(requestID: "request-1", succeeded: false),
            .startRejected(gestureID: id.uuidString))
        harness.resume()
        XCTAssertEqual(harness.sent, [RemoteCommand(name: .pointerButtonDown, button: .left), key])
        XCTAssertFalse(harness.move(id, x: 1, y: 1))
        XCTAssertNotNil(harness.begin())
    }

    func testResetDiscardsPendingMotionAndIgnoresLateAcknowledgement() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        _ = harness.move(id, x: 70, y: 90)
        harness.end(id)
        harness.coordinator.reset()
        XCTAssertNil(harness.coordinator.acceptResult(requestID: "request-1", succeeded: true))
        harness.resume()
        XCTAssertEqual(harness.sent.count, 1)
        XCTAssertNotNil(harness.begin())
    }

    func testFailedStartEnqueueRetainsNoDrag() {
        let coordinator = LocalPointerDragCoordinator()
        XCTAssertNil(coordinator.begin(trackResults: true, send: { _ in false }))
        XCTAssertNotNil(coordinator.begin(trackResults: false, send: { _ in true }))
    }

    func testFixtureModeDoesNotWaitForAcknowledgement() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin(trackResults: false))
        XCTAssertTrue(harness.move(id, x: 2, y: 3))
        harness.end(id)
        XCTAssertEqual(
            harness.sent.map(\.name), [.pointerButtonDown, .pointerMove, .pointerButtonUp])
    }

    func testBackpressureRetainsEveryChunkAndOrdersReleaseBeforeLaterInput() throws {
        let coordinator = LocalPointerDragCoordinator()
        var scheduler = InputCommandScheduler(capacity: 2)
        var wire: [RemoteCommand] = []
        let send: (RemoteCommand) -> Bool = { command in
            if command.name == .pointerButtonDown {
                wire.append(command)
                coordinator.registerDispatchedCommand(command, requestID: "down")
                return true
            }
            return scheduler.enqueue(command, preservingMotion: true)
        }
        let id = try XCTUnwrap(coordinator.begin(trackResults: true, send: send))
        for _ in 0..<4 { XCTAssertTrue(coordinator.move(id, x: 450, y: -200, send: send)) }
        coordinator.end(id, send: send)
        let key = RemoteCommand(name: .keyboardKey, key: .returnKey)
        XCTAssertEqual(coordinator.deferCommandIfNeeded(key), true)
        _ = coordinator.acceptResult(requestID: "down", succeeded: true)
        coordinator.resume(send: send)
        for _ in 0..<12 {
            wire += scheduler.dequeue(maximumCount: 1)
            coordinator.resume(send: send)
        }
        XCTAssertTrue(scheduler.queuedCommands.isEmpty)
        let moves = wire.filter { $0.name == .pointerMove }
        XCTAssertEqual(moves.compactMap(\.x).reduce(0, +), 1800)
        XCTAssertEqual(moves.compactMap(\.y).reduce(0, +), -800)
        XCTAssertTrue(moves.allSatisfy { (try? $0.validate()) != nil })
        XCTAssertEqual(
            Array(wire.suffix(2)), [RemoteCommand(name: .pointerButtonUp, button: .left), key])
        XCTAssertEqual(wire.filter { $0.name == .pointerButtonUp }.count, 1)
    }

    func testDeferredInputQueueIsBounded() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        harness.end(id)
        for _ in 0..<8 {
            XCTAssertEqual(
                harness.coordinator.deferCommandIfNeeded(
                    RemoteCommand(name: .keyboardKey, key: .left)), true)
        }
        XCTAssertEqual(
            harness.coordinator.deferCommandIfNeeded(
                RemoteCommand(name: .keyboardKey, key: .right)), false)
    }

    func testInvalidMotionDoesNotCorruptBuffer() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        XCTAssertFalse(harness.move(id, x: .nan, y: 1))
        XCTAssertFalse(harness.move(id, x: 501, y: 0))
        XCTAssertTrue(harness.move(id, x: 12, y: 4))
        _ = harness.coordinator.acceptResult(requestID: "request-1", succeeded: true)
        harness.end(id)
        XCTAssertEqual(harness.sent[1], RemoteCommand(name: .pointerMove, x: 12, y: 4))
    }

    func testAcceptedStartWithFailedReleaseRequiresTeardown() throws {
        let harness = DragHarness()
        let id = try XCTUnwrap(harness.begin())
        harness.end(id)
        _ = harness.coordinator.acceptResult(requestID: "request-1", succeeded: true)
        harness.resume()
        XCTAssertEqual(
            harness.coordinator.acceptResult(requestID: "request-2", succeeded: false),
            .releaseFailureRequiresSessionTeardown(gestureID: id.uuidString))
    }
}

@MainActor
private final class DragHarness {
    let coordinator = LocalPointerDragCoordinator()
    var sent: [RemoteCommand] = []

    func send(_ command: RemoteCommand) -> Bool {
        sent.append(command)
        coordinator.registerDispatchedCommand(command, requestID: "request-\(sent.count)")
        return true
    }

    func begin(trackResults: Bool = true) -> UUID? {
        coordinator.begin(trackResults: trackResults, send: send)
    }

    func move(_ id: UUID, x: Double, y: Double) -> Bool {
        coordinator.move(id, x: x, y: y, send: send)
    }

    func end(_ id: UUID) { coordinator.end(id, send: send) }
    func resume() { coordinator.resume(send: send) }
}
