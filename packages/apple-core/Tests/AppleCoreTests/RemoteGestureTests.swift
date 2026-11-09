import AppleCore
import Foundation
import XCTest

final class RemoteGestureTests: XCTestCase {
    private let id = UUID()

    private func command(_ phase: RemoteGesturePhase, _ value: Double, time: Double = 10)
        -> RemoteCommand
    {
        RemoteCommand(
            name: .gesture,
            gesture: RemoteGestureFrame(
                id: id, kind: .magnify, phase: phase, value: value, timestamp: time))
    }

    func testGestureRoundTripAndStrictValidation() throws {
        let message = WireMessage(
            type: .command, connectionID: "connection", requestID: UUID().uuidString,
            sequence: 1, command: command(.changed, 0.3))
        XCTAssertEqual(try WireCodec.decode(WireCodec.encode(message)), message)
        for value in [Double.nan, .infinity, -Double.infinity, 4.001, -4.001] {
            XCTAssertThrowsError(try command(.changed, value).validate())
        }
        XCTAssertThrowsError(try command(.began, 0.1).validate())
        XCTAssertThrowsError(try command(.changed, 0, time: -1).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .gesture).validate())
        var extra = command(.changed, 0.1)
        extra.x = 1
        XCTAssertThrowsError(try extra.validate())
        extra = command(.changed, 0.1)
        extra.name = .pointerClick
        extra.button = .left
        XCTAssertThrowsError(try extra.validate())
        let encoded = try JSONEncoder().encode(command(.changed, 0.1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var frame = try XCTUnwrap(object["gesture"] as? [String: Any])
        frame["arbitraryHIDType"] = 23
        object["gesture"] = frame
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteCommand.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testSymmetricPinchStartsWithoutCentroidMotionAndCannotTurnIntoScroll() {
        var policy = TwoFingerGesturePolicy()
        policy.begin(span: 100)
        XCTAssertEqual(policy.update(span: 102, translationX: 1, translationY: 0), .pending)
        XCTAssertEqual(policy.update(span: 120, translationX: 0, translationY: 0), .magnify)
        XCTAssertEqual(exp(policy.magnification(span: 150)), 1.5, accuracy: 0.000001)
        XCTAssertEqual(policy.update(span: 150, translationX: 80, translationY: 0), .magnify)
    }

    func testPanLocksOutPinchAndNearbyFingersCannotCreateExtremeZoom() {
        var policy = TwoFingerGesturePolicy()
        policy.begin(span: 100)
        XCTAssertEqual(policy.update(span: 102, translationX: 0, translationY: 12), .scroll)
        XCTAssertEqual(policy.update(span: 200, translationX: 0, translationY: 12), .scroll)
        policy.begin(span: 4)
        XCTAssertEqual(policy.update(span: 7, translationX: 0, translationY: 0), .pending)
        XCTAssertEqual(policy.magnification(span: 7), 0)
        policy.begin(span: 100)
        XCTAssertEqual(policy.update(span: .nan, translationX: 10, translationY: 0), .pending)
        XCTAssertEqual(policy.magnification(span: 0), log(0.08), accuracy: 0.000001)
    }

    func testCloseStartingFingersCanGrowIntoPinchWithoutUnboundedScale() {
        var policy = TwoFingerGesturePolicy()
        policy.begin(span: 7.31)
        XCTAssertEqual(policy.update(span: 14.38, translationX: 0, translationY: 0), .magnify)
        XCTAssertEqual(exp(policy.magnification(span: 20.67)), 20.67 / 8, accuracy: 0.000001)
        policy.begin(span: 0)
        XCTAssertEqual(policy.magnification(span: 0), 0)
        XCTAssertEqual(policy.update(span: 4, translationX: 0, translationY: 0), .pending)
        XCTAssertEqual(policy.update(span: 16, translationX: 0, translationY: 0), .magnify)
        XCTAssertEqual(exp(policy.magnification(span: 16)), 2, accuracy: 0.000001)
    }

    func testPinchMotionIsNotATwoFingerTap() {
        var fingers = TouchFingerMovementTracker<Int>()
        fingers.begin(id: 1, x: -50, y: 0)
        fingers.begin(id: 2, x: 50, y: 0)
        fingers.record(id: 1, x: -70, y: 0)
        fingers.record(id: 2, x: 70, y: 0)
        XCTAssertFalse(fingers.staysWithinTwoFingerTapSlop(threshold: 7))
    }

    func testCumulativeUpdatesCoalesceWithoutLosingBeginOrEnd() {
        var scheduler = InputCommandScheduler(capacity: 3)
        let start = command(.began, 0)
        let first = command(.changed, 0.1)
        let latest = command(.changed, 0.3, time: 10.1)
        let end = command(.ended, 0.3, time: 10.2)
        XCTAssertTrue(scheduler.enqueue(start))
        XCTAssertTrue(scheduler.enqueue(first))
        XCTAssertTrue(scheduler.enqueue(latest))
        XCTAssertTrue(scheduler.enqueue(end))
        XCTAssertFalse(scheduler.enqueue(command(.changed, 0.4, time: 10.3)))
        XCTAssertEqual(scheduler.dequeue(maximumCount: 8), [start, latest, end])
    }

    func testNoCoalescingAcrossGestureIdentityOrDiscreteBarriers() {
        var scheduler = InputCommandScheduler()
        let first = command(.changed, 0.1)
        let key = RemoteCommand(name: .keyboardKey, key: .escape)
        let next = command(.changed, 0.2)
        let other = RemoteCommand(
            name: .gesture,
            gesture: RemoteGestureFrame(
                id: UUID(), kind: .magnify, phase: .changed, value: 0.3, timestamp: 11))
        for command in [first, key, next, other] { XCTAssertTrue(scheduler.enqueue(command)) }
        XCTAssertEqual(scheduler.queuedCommands, [first, key, next, other])
    }

    func testTerminalFlushIsImmediateAndFailureRequiresSessionCleanup() {
        let now = ContinuousClock.now
        var dispatcher = InputCommandDispatcher()
        XCTAssertTrue(dispatcher.enqueue(command(.changed, 0.1)))
        _ = dispatcher.dequeue(maximumCount: 8, at: now)
        XCTAssertTrue(dispatcher.enqueue(command(.changed, 0.2)))
        XCTAssertGreaterThan(dispatcher.flushDelay(at: now, maximumCount: 8) ?? .zero, .zero)
        let end = command(.ended, 0.2)
        XCTAssertTrue(dispatcher.enqueue(end))
        XCTAssertEqual(dispatcher.flushDelay(at: now, maximumCount: 8), .zero)
        let request = UUID().uuidString
        let metadata = PendingCommandMetadata(
            connectionID: "c", requestID: request, sequence: 1, command: end)
        let result = WireMessage(
            type: .result, connectionID: "c", requestID: request, sequence: 1,
            error: RemoteError(code: "failed", message: "failed"))
        XCTAssertTrue(metadata.requiresSessionTeardown(for: result))
        XCTAssertTrue(PointerOwnershipPolicy.blocks(end, heldBy: UUID(), requester: UUID()))
    }

    func testFourFingerAxisAndProgressCanReverseWithoutChangingAxis() {
        let kind = FourFingerGesturePolicy.kind(x: 0, y: -12)
        XCTAssertEqual(kind, .verticalSwipe)
        XCTAssertEqual(FourFingerGesturePolicy.progress(kind: kind, x: 0, y: -110), 0.5)
        XCTAssertEqual(FourFingerGesturePolicy.progress(kind: kind, x: 0, y: -22), 0.1)
        XCTAssertEqual(FourFingerGesturePolicy.progress(kind: .horizontalSwipe, x: -500, y: 10), -1)
    }
}
