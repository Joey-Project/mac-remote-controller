import XCTest
@testable import AppleCore

final class TouchGesturePolicyTests: XCTestCase {
    func testTouchCountsSelectOnlyEnabledGestureKinds() {
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 1, dragEnabled: false, shortcutsEnabled: false),
            .pointer)
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 2, dragEnabled: false, shortcutsEnabled: false),
            .scroll)
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 3, dragEnabled: true, shortcutsEnabled: true), .drag
        )
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 3, dragEnabled: false, shortcutsEnabled: true),
            .ignore)
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 4, dragEnabled: true, shortcutsEnabled: true),
            .shortcutSwipe)
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 4, dragEnabled: true, shortcutsEnabled: false),
            .ignore)
        XCTAssertEqual(
            TouchGesturePolicy.kind(touchCount: 5, dragEnabled: true, shortcutsEnabled: true),
            .ignore)
    }

    func testFourFingerSwipeDirectionMappingAndDistanceGate() {
        XCTAssertEqual(TouchGesturePolicy.shortcut(deltaX: 0, deltaY: -80), .missionControl)
        XCTAssertEqual(TouchGesturePolicy.shortcut(deltaX: 0, deltaY: 80), .appExpose)
        XCTAssertEqual(TouchGesturePolicy.shortcut(deltaX: -80, deltaY: 0), .previousSpace)
        XCTAssertEqual(TouchGesturePolicy.shortcut(deltaX: 80, deltaY: 0), .nextSpace)
        XCTAssertNil(TouchGesturePolicy.shortcut(deltaX: .nan, deltaY: 90))
        XCTAssertNil(TouchGesturePolicy.shortcut(deltaX: 20, deltaY: 20))
    }

    func testTwoFingerTapRequiresBothFingersToStayWithinTapSlop() {
        XCTAssertTrue(
            TouchGesturePolicy.isTwoFingerTapWithinSlop(
                perFingerDisplacements: [6.9, 6.9], threshold: 7))
        XCTAssertFalse(
            TouchGesturePolicy.isTwoFingerTapWithinSlop(
                perFingerDisplacements: [8, 8], threshold: 7))
        XCTAssertFalse(
            TouchGesturePolicy.isTwoFingerTapWithinSlop(
                perFingerDisplacements: [0, 7], threshold: 7))
        XCTAssertFalse(
            TouchGesturePolicy.isTwoFingerTapWithinSlop(
                perFingerDisplacements: [0], threshold: 7))
        XCTAssertFalse(
            TouchGesturePolicy.isTwoFingerTapWithinSlop(
                perFingerDisplacements: [.nan, 0], threshold: 7))
    }

    func testStaggeredTwoFingerLiftRetainsOpposingFingerMovement() {
        var movement = TouchFingerMovementTracker<String>()
        movement.begin(id: "first", x: 0, y: 0)
        movement.begin(id: "second", x: 10, y: 0)
        movement.record(id: "first", x: 0, y: 8)
        XCTAssertEqual(movement.fingerCount, 2)

        // The final ended batch may contain only the second finger. The first
        // finger's final displacement remains part of the same tap decision.
        movement.record(id: "second", x: 10, y: -8)
        XCTAssertEqual(movement.displacements.sorted(), [8, 8])
        XCTAssertFalse(movement.staysWithinTwoFingerTapSlop(threshold: 7))
    }

    func testTwoFingerTapAllowsSmallOpposingMovementForBothFingers() {
        var movement = TouchFingerMovementTracker<String>()
        movement.begin(id: "first", x: 0, y: 0)
        movement.begin(id: "second", x: 10, y: 0)
        movement.record(id: "first", x: 0, y: 6.9)
        movement.record(id: "second", x: 10, y: -6.9)

        XCTAssertTrue(movement.staysWithinTwoFingerTapSlop(threshold: 7))
    }

    func testPendingTouchesMayJoinInSeparateBatchesAndLiftInSeparateBatches() {
        var sequence = TouchSequencePolicy()
        XCTAssertEqual(sequence.begin(adding: 1, at: 10), .started)
        XCTAssertEqual(sequence.begin(adding: 1, at: 10.1), .joined)
        XCTAssertEqual(sequence.initialCount, 2)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true, at: 10.2),
            .partialPendingLift)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true, at: 10.3),
            .ended(.scroll, tapAllowed: true))
    }

    func testPendingSequenceCancelsWhenAnotherFingerJoinsAfterPartialLift() {
        var sequence = TouchSequencePolicy()
        XCTAssertEqual(sequence.begin(adding: 2, at: 4), .started)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true, at: 4.1),
            .partialPendingLift)
        XCTAssertEqual(sequence.begin(adding: 1, at: 4.2), .cancelled)
        XCTAssertFalse(sequence.isPending)

        sequence.cancel()
        XCTAssertEqual(sequence.begin(adding: 2, at: 5), .started)
        XCTAssertTrue(sequence.isPending)
    }

    func testLongPendingHoldSuppressesOneAndTwoFingerTapsButMovementCanStart() {
        var single = TouchSequencePolicy()
        XCTAssertEqual(single.begin(adding: 1, at: 20), .started)
        XCTAssertEqual(
            single.end(removing: 1, dragEnabled: true, shortcutsEnabled: true, at: 20.51),
            .ended(.pointer, tapAllowed: false))

        var two = TouchSequencePolicy()
        XCTAssertEqual(two.begin(adding: 2, at: 30), .started)
        XCTAssertEqual(
            two.end(removing: 2, dragEnabled: true, shortcutsEnabled: true, at: 30.51),
            .ended(.scroll, tapAllowed: false))

        var moved = TouchSequencePolicy()
        XCTAssertEqual(moved.begin(adding: 1, at: 40), .started)
        moved.activate()
        XCTAssertEqual(
            moved.end(removing: 1, dragEnabled: true, shortcutsEnabled: true, at: 41), .cancelled)
    }

    func testNormalOneFingerTapRemainsAllowed() {
        var sequence = TouchSequencePolicy()
        XCTAssertEqual(sequence.begin(adding: 1, at: 2), .started)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: false, shortcutsEnabled: false, at: 2.49),
            .ended(.pointer, tapAllowed: true))
    }

    func testTapDurationUsesFiniteMonotonicTimestamps() {
        XCTAssertTrue(TouchGesturePolicy.isTapDurationAllowed(startedAt: 1, endedAt: 1.5))
        XCTAssertFalse(TouchGesturePolicy.isTapDurationAllowed(startedAt: 1, endedAt: 1.501))
        XCTAssertFalse(TouchGesturePolicy.isTapDurationAllowed(startedAt: 2, endedAt: 1.9))
        XCTAssertFalse(TouchGesturePolicy.isTapDurationAllowed(startedAt: .nan, endedAt: 1))
    }

    func testFingerCountChangeAfterGestureStartsCancelsWithoutTapOutcome() {
        var sequence = TouchSequencePolicy()
        XCTAssertEqual(sequence.begin(adding: 2), .started)
        sequence.activate()
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true), .cancelled)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true), .ignored)
    }

    func testMovementThresholdBeginsGestureAndKeepsAccumulatedDelta() {
        XCTAssertFalse(TouchGesturePolicy.shouldBeginMovement(distance: 6.9, threshold: 7))
        XCTAssertTrue(TouchGesturePolicy.shouldBeginMovement(distance: 7, threshold: 7))
        XCTAssertFalse(TouchGesturePolicy.shouldBeginMovement(distance: .infinity, threshold: 7))
    }
}
