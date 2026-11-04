import Foundation
import XCTest
import dnssd
@testable import AppleCore

final class BonjourResolverTests: XCTestCase {
    func testOnlyExplicitConnectionResolutionRequestsNetworkWake() {
        XCTAssertEqual(BonjourResolver.resolveFlags(wakeOnResolve: false), 0)
        XCTAssertEqual(
            BonjourResolver.resolveFlags(wakeOnResolve: true),
            DNSServiceFlags(kDNSServiceFlagsWakeOnResolve))
        XCTAssertEqual(BonjourResolver.resolutionTimeout(wakeOnResolve: false), 5)
        XCTAssertEqual(BonjourResolver.resolutionTimeout(wakeOnResolve: true), 15)
    }

    func testBuildsWSSURLFromResolvedHostAndPort() throws {
        let url = try BonjourResolver.webSocketURL(host: "sofa-mac.local.", port: 12_345)

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "sofa-mac.local.")
        XCTAssertEqual(url.port, 12_345)
        XCTAssertEqual(url.path, "/")
    }

    func testRejectsInvalidResolvedHost() {
        XCTAssertThrowsError(try BonjourResolver.webSocketURL(host: "", port: 443))
        XCTAssertThrowsError(try BonjourResolver.webSocketURL(host: "bad host.local", port: 443))
        XCTAssertThrowsError(try BonjourResolver.webSocketURL(host: "host/path", port: 443))
    }
}
