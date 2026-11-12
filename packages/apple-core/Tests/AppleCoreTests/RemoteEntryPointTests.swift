import Foundation
import XCTest
@testable import AppleCore

final class RemoteEntryPointTests: XCTestCase {
    func testEntryPointsRoundTripWithoutDeviceData() {
        for entry in RemoteEntryPoint.allCases {
            XCTAssertEqual(RemoteEntryPoint(url: entry.url), entry)
            XCTAssertEqual(entry.url.absoluteString, "sofaremote://remote/\(entry.rawValue)")
        }
    }

    func testRejectsCommandsCredentialsAndNoncanonicalRoutes() throws {
        let invalid = [
            "https://remote/keyboard", "sofaremote://other/keyboard",
            "sofaremote://remote/unlock", "sofaremote://remote/keyboard/",
            "sofaremote://remote/%6beyboard", "sofaremote://remote/../keyboard",
            "sofaremote://remote/Keyboard", "sofaremote://remote",
            "sofaremote://remote/keyboard?device=anything",
            "sofaremote://remote/keyboard?", "sofaremote://remote/keyboard#",
            "sofaremote://user@remote/keyboard", "sofaremote://remote:443/keyboard"
        ]
        for value in invalid {
            XCTAssertNil(RemoteEntryPoint(url: try XCTUnwrap(URL(string: value))), value)
        }
    }
}
