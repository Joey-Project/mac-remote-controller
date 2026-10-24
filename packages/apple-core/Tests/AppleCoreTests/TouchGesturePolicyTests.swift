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

    func testPendingTouchesMayJoinInSeparateBatchesAndLiftInSeparateBatches() {
        var sequence = TouchSequencePolicy()
        XCTAssertEqual(sequence.begin(adding: 1), .started)
        XCTAssertEqual(sequence.begin(adding: 1), .joined)
        XCTAssertEqual(sequence.initialCount, 2)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true),
            .partialPendingLift)
        XCTAssertEqual(
            sequence.end(removing: 1, dragEnabled: true, shortcutsEnabled: true), .ended(.scroll))
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
