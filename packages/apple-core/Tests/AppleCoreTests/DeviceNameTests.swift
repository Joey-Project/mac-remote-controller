import XCTest
@testable import AppleCore

final class DeviceNameTests: XCTestCase {
    func testBoundedNamePreservesExactUTF8ByteBoundary() {
        let exactBoundary = String(repeating: "é", count: 128)
        let overBoundary = exactBoundary + "é"

        XCTAssertEqual(DeviceName.bounded(exactBoundary), exactBoundary)
        XCTAssertEqual(DeviceName.bounded(exactBoundary).utf8.count, 256)
        XCTAssertEqual(DeviceName.bounded(overBoundary), exactBoundary)
    }

    func testBoundedNameKeepsWholeOversizedGraphemeSequenceWithinLimit() {
        let family = "👨‍👩‍👧‍👦"
        let name = String(repeating: family, count: 40)

        let bounded = DeviceName.bounded(name)

        XCTAssertFalse(bounded.isEmpty)
        XCTAssertLessThanOrEqual(bounded.utf8.count, WireLimits.maximumDeviceNameBytes)
        XCTAssertEqual(bounded, String(repeating: family, count: 10))
    }

    func testBoundedNameFallsBackWhenOneGraphemeExceedsLimit() {
        let oversizedCombiningGrapheme = "a" + String(repeating: "\u{301}", count: 300)

        XCTAssertEqual(DeviceName.bounded(oversizedCombiningGrapheme), "iOS device")
    }

    func testBoundedNameUsesFallbackForEmptyInput() {
        XCTAssertEqual(DeviceName.bounded(""), "iOS device")
    }
}
