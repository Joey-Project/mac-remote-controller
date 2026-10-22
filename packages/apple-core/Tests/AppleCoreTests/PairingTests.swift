import Foundation
import XCTest
@testable import AppleCore

final class PairingTests: XCTestCase {
    func testInvitationURLRoundTripsWithRuntimeToken() throws {
        let now = Date()
        let invitation = PairingInvitation(
            serviceName: UUID().uuidString,
            certificateSHA256: PairingSecurity.fingerprint(Data("certificate-a".utf8)),
            token: try PairingSecurity.randomToken(),
            expiresAt: now.addingTimeInterval(180)
        )

        let parsed = try PairingInvitation.parse(invitation.url(), now: now)

        XCTAssertEqual(parsed, invitation)
    }

    func testInvitationRejectsMalformedFingerprintServiceAndToken() throws {
        let now = Date()
        let validServiceName = UUID().uuidString
        let validFingerprint = String(repeating: "a", count: 64)
        let validToken = try PairingSecurity.randomToken()

        XCTAssertThrowsError(
            try PairingInvitation.parse(
                makeInvitation(
                    serviceName: "not-a-uuid",
                    fingerprint: validFingerprint,
                    token: validToken,
                    expiresAt: now.addingTimeInterval(60)
                ).url(),
                now: now
            )
        )
        XCTAssertThrowsError(
            try PairingInvitation.parse(
                makeInvitation(
                    serviceName: validServiceName,
                    fingerprint: String(repeating: "a", count: 63),
                    token: validToken,
                    expiresAt: now.addingTimeInterval(60)
                ).url(),
                now: now
            )
        )
        XCTAssertThrowsError(
            try PairingInvitation.parse(
                makeInvitation(
                    serviceName: validServiceName,
                    fingerprint: String(repeating: "a", count: 63) + "G",
                    token: validToken,
                    expiresAt: now.addingTimeInterval(60)
                ).url(),
                now: now
            )
        )
        XCTAssertThrowsError(
            try PairingInvitation.parse(
                makeInvitation(
                    serviceName: validServiceName,
                    fingerprint: validFingerprint,
                    token: Data((0..<31).map(UInt8.init)).base64EncodedString(),
                    expiresAt: now.addingTimeInterval(60)
                ).url(),
                now: now
            )
        )
    }

    func testInvitationRejectsExpiredAndTooFarFutureExpiry() throws {
        let now = Date()
        let token = try PairingSecurity.randomToken()
        let fingerprint = String(repeating: "b", count: 64)

        let expired = makeInvitation(
            serviceName: UUID().uuidString,
            fingerprint: fingerprint,
            token: token,
            expiresAt: now
        )
        XCTAssertThrowsError(try PairingInvitation.parse(expired.url(), now: now))

        let tooFarFuture = makeInvitation(
            serviceName: UUID().uuidString,
            fingerprint: fingerprint,
            token: token,
            expiresAt: now.addingTimeInterval(301)
        )
        XCTAssertThrowsError(try PairingInvitation.parse(tooFarFuture.url(), now: now))
    }

    func testInvitationRejectsMalformedURLPayload() {
        XCTAssertThrowsError(try PairingInvitation.parse("https://example.invalid/pair"))
        XCTAssertThrowsError(try PairingInvitation.parse("sofaremote://pair/not-base64"))
    }

    func testFingerprintAndComparisonUseFullInput() {
        let first = PairingSecurity.fingerprint(Data("certificate-a".utf8))
        let second = PairingSecurity.fingerprint(Data("certificate-b".utf8))

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(first, PairingSecurity.fingerprint(Data("certificate-a".utf8)))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(PairingSecurity.matches(first, first))
        XCTAssertFalse(PairingSecurity.matches(first, second))
        XCTAssertFalse(PairingSecurity.matches(first, first + "0"))
    }

    func testPairedMacCodableRoundTrip() throws {
        let pairedMac = PairedMac(
            serviceName: UUID().uuidString,
            name: "Living Room Mac",
            certificateSHA256: PairingSecurity.fingerprint(Data("certificate".utf8)),
            token: try PairingSecurity.randomToken()
        )

        let encoded = try JSONEncoder().encode(pairedMac)
        let decoded = try JSONDecoder().decode(PairedMac.self, from: encoded)

        XCTAssertEqual(decoded, pairedMac)
    }

    private func makeInvitation(
        serviceName: String,
        fingerprint: String,
        token: String,
        expiresAt: Date
    ) -> PairingInvitation {
        PairingInvitation(
            serviceName: serviceName,
            certificateSHA256: fingerprint,
            token: token,
            expiresAt: expiresAt
        )
    }
}
