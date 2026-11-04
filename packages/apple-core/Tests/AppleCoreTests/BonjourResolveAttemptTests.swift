import XCTest
import dnssd
@testable import AppleCore

final class BonjourResolveAttemptTests: XCTestCase {
    func testUnsupportedWakeFallsBackImmediatelyExactlyOnce() {
        let rejections = [
            kDNSServiceErr_BadParam, kDNSServiceErr_BadFlags, kDNSServiceErr_Unsupported
        ]
        for rejection in rejections {
            var flags: [DNSServiceFlags] = []
            let result = BonjourResolveAttempt.start(
                wakeOnResolve: true, interfaceIndex: 4
            ) { flag in
                flags.append(flag)
                return DNSServiceErrorType(flag == 0 ? kDNSServiceErr_NoError : rejection)
            }
            XCTAssertEqual(flags, [DNSServiceFlags(kDNSServiceFlagsWakeOnResolve), 0])
            XCTAssertEqual(result.status, DNSServiceErrorType(kDNSServiceErr_NoError))
            XCTAssertFalse(result.usedWake)
        }
    }

    func testSupportedWakeRemainsOneAttempt() {
        var count = 0
        let result = BonjourResolveAttempt.start(wakeOnResolve: true, interfaceIndex: 4) { _ in
            count += 1
            return DNSServiceErrorType(kDNSServiceErr_NoError)
        }
        XCTAssertEqual(count, 1)
        XCTAssertTrue(result.usedWake)
    }

    func testOrdinaryResolutionAndUnrelatedErrorsDoNotRetry() {
        for wake in [false, true] {
            var count = 0
            let result = BonjourResolveAttempt.start(wakeOnResolve: wake, interfaceIndex: 4) { _ in
                count += 1
                return DNSServiceErrorType(kDNSServiceErr_NoAuth)
            }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(result.status, DNSServiceErrorType(kDNSServiceErr_NoAuth))
        }
    }

    func testFallbackFailurePropagatesWithoutLooping() {
        var count = 0
        let result = BonjourResolveAttempt.start(wakeOnResolve: true, interfaceIndex: 4) { _ in
            count += 1
            return DNSServiceErrorType(
                count == 1 ? kDNSServiceErr_BadParam : kDNSServiceErr_ServiceNotRunning)
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result.status, DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))
        XCTAssertFalse(result.usedWake)
    }

    func testUnknownAndReservedInterfacesNeverRequestWake() {
        for index in [
            UInt32(0), kDNSServiceInterfaceIndexLocalOnly, kDNSServiceInterfaceIndexUnicast,
            kDNSServiceInterfaceIndexP2P, kDNSServiceInterfaceIndexBLE
        ] {
            var flags: [DNSServiceFlags] = []
            let result = BonjourResolveAttempt.start(
                wakeOnResolve: true, interfaceIndex: index
            ) { flag in
                flags.append(flag)
                return DNSServiceErrorType(kDNSServiceErr_NoError)
            }
            XCTAssertEqual(flags, [0])
            XCTAssertFalse(result.usedWake)
        }
    }
}
