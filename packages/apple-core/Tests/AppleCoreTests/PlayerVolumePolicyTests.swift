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
        XCTAssertEqual(try snapped(96, maximum: 200), 100)
        XCTAssertEqual(try snapped(104, maximum: 200), 100)
        XCTAssertEqual(try snapped(105, maximum: 200), 100)
        XCTAssertEqual(try snapped(106, maximum: 200), 110)
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
