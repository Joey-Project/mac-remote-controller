import AppleCore
import XCTest

final class PlayerVolumePolicyTests: XCTestCase {
    func testTenPointStepsAreAbsoluteForCommonAdapterMaximums() throws {
        for maximum in [100.0, 130.0, 200.0] {
            XCTAssertEqual(try snapped(90, maximum: maximum), 90)
            XCTAssertEqual(try snapped(100, maximum: maximum), 100)
            XCTAssertEqual(
                try snapped(110, maximum: maximum), maximum >= 110 ? 110 : maximum)
        }
    }

    func testOneHundredIsTheStrongestDetentEvenWhenMaximumIsHigher() throws {
        XCTAssertTrue(PlayerVolumePolicy.isAtStrongestDetent(100))
        XCTAssertFalse(PlayerVolumePolicy.isAtStrongestDetent(130))
        XCTAssertEqual(try snapped(93, maximum: 200), 100)
        XCTAssertEqual(try snapped(107, maximum: 200), 100)
        XCTAssertEqual(try snapped(92, maximum: 200), 90)
        XCTAssertEqual(try snapped(108, maximum: 200), 110)
    }

    func testZeroAndAdapterMaximumRemainExactEndpoints() throws {
        for maximum in [100.0, 130.0, 200.0] {
            XCTAssertEqual(try snapped(-20, maximum: maximum), 0)
            XCTAssertEqual(try snapped(maximum, maximum: maximum), maximum)
            XCTAssertEqual(try snapped(maximum + 20, maximum: maximum), maximum)
        }
        XCTAssertEqual(try snapped(135, maximum: 135), 135)
        XCTAssertEqual(try snapped(1.5, maximum: 1.5), 1.5)
    }

    func testAccessibilityAdjustmentsUseAbsoluteTenPointSteps() throws {
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 90, increasing: true, maximum: 200)),
            100)
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 100, increasing: true, maximum: 200)),
            110)
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 110, increasing: false, maximum: 200)),
            100)
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 100, increasing: false, maximum: 200)),
            90)
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 120, increasing: true, maximum: 130)),
            130)
        XCTAssertEqual(
            try XCTUnwrap(
                PlayerVolumePolicy.accessibilityAdjustedValue(
                    current: 130, increasing: false, maximum: 130)),
            120)
    }

    func testDuplicateSnappedValuesDoNotSendAgain() {
        XCTAssertTrue(PlayerVolumePolicy.shouldSend(value: 100, current: 90, previouslySent: 90))
        XCTAssertFalse(PlayerVolumePolicy.shouldSend(value: 100, current: 100, previouslySent: 90))
        XCTAssertFalse(PlayerVolumePolicy.shouldSend(value: 100, current: 90, previouslySent: 100))
    }

    func testNonFiniteProposalsAndInvalidMaximumAreRejected() {
        XCTAssertNil(PlayerVolumePolicy.snappedValue(proposed: .nan, maximum: 130))
        XCTAssertNil(PlayerVolumePolicy.snappedValue(proposed: .infinity, maximum: 130))
        XCTAssertNil(PlayerVolumePolicy.snappedValue(proposed: 10, maximum: .infinity))
        XCTAssertNil(PlayerVolumePolicy.snappedValue(proposed: 10, maximum: 0))
    }

    private func snapped(_ proposed: Double, maximum: Double) throws -> Double {
        try XCTUnwrap(PlayerVolumePolicy.snappedValue(proposed: proposed, maximum: maximum))
    }
}
