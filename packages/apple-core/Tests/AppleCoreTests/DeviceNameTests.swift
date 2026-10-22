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

    func testMacRemoteStateUsesFallbackForEmptyName() throws {
        try assertValidMacRemoteState(for: "", expectedName: "Mac")
    }

    func testMacRemoteStateBoundsOversizedMultibyteName() throws {
        let oversizedName = String(repeating: "é", count: 129)

        try assertValidMacRemoteState(
            for: oversizedName, expectedName: String(repeating: "é", count: 128))
    }

    func testMacRemoteStateUsesFallbackForOversizedGrapheme() throws {
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 300)

        try assertValidMacRemoteState(for: oversizedGrapheme, expectedName: "Mac")
    }

    func testFallbackCannotViolateRemoteStateDeviceNameLimits() throws {
        let oversizedGrapheme = "a" + String(repeating: "\u{301}", count: 300)
        let oversizedMultibyteFallback = String(repeating: "é", count: 129)

        for fallback in ["", oversizedGrapheme, oversizedMultibyteFallback] {
            let name = DeviceName.bounded("", fallback: fallback)
            let state = RemoteState(
                accessibilityGranted: true, systemVolume: nil, deviceName: name)

            XCTAssertFalse(name.isEmpty)
            XCTAssertLessThanOrEqual(name.utf8.count, WireLimits.maximumDeviceNameBytes)
            XCTAssertNoThrow(try state.validate())
        }

        XCTAssertEqual(DeviceName.bounded("", fallback: ""), "Device")
        XCTAssertEqual(DeviceName.bounded("", fallback: oversizedGrapheme), "Device")
        XCTAssertEqual(
            DeviceName.bounded("", fallback: oversizedMultibyteFallback),
            String(repeating: "é", count: 128))
    }

    private func assertValidMacRemoteState(for name: String, expectedName: String) throws {
        let boundedName = DeviceName.bounded(name, fallback: "Mac")
        let state = RemoteState(
            accessibilityGranted: true, systemVolume: nil, deviceName: boundedName)

        XCTAssertEqual(boundedName, expectedName)
        XCTAssertNoThrow(try state.validate())
    }
}
