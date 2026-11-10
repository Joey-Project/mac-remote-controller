import Foundation
import XCTest
@testable import AppleCore

final class NumericPairingPolicyTests: XCTestCase {
    func testThirdFailureInvalidatesCodeAndCannotBeReset() {
        var budget = NumericPairingAttemptBudget(startedAt: 0)
        XCTAssertEqual(budget.remainingAttempts, 3)
        for now in 1...3 { budget.recordFailure(at: Double(now)) }
        XCTAssertEqual(budget.remainingAttempts, 0)
        XCTAssertFalse(budget.isActive(at: 4))
        XCTAssertFalse(budget.consume(at: 4))
        budget.recordFailure(at: 5)
        XCTAssertEqual(budget.remainingAttempts, 0)
    }

    func testCodeExpiresAndSuccessfulConsumptionIsSingleUse() {
        var budget = NumericPairingAttemptBudget(startedAt: 10)
        XCTAssertEqual(budget.expiresIn(at: 10), 120)
        XCTAssertEqual(budget.expiresIn(at: 129.5), 1)
        XCTAssertFalse(budget.isActive(at: 130))
        XCTAssertFalse(budget.consume(at: 130))
        budget = NumericPairingAttemptBudget(startedAt: 200)
        XCTAssertTrue(budget.consume(at: 201))
        XCTAssertFalse(budget.consume(at: 201))
        XCTAssertFalse(budget.isActive(at: 202))
    }

    func testGlobalLimitsSurviveReplacementCodesAndBackwardsTime() {
        var limiter = NumericPairingRequestLimiter()
        for now in 0..<3 {
            XCTAssertTrue(limiter.admitRequest(at: Double(now)))
            limiter.recordFailure(at: Double(now) + 0.5)
        }
        XCTAssertFalse(limiter.admitRequest(at: 4))
        XCTAssertFalse(limiter.mayAttempt(at: 4))
        XCTAssertFalse(limiter.admitRequest(at: -1))
        XCTAssertFalse(limiter.mayAttempt(at: .nan))
        XCTAssertTrue(limiter.admitRequest(at: 63))
    }

    func testRequestFloodIsBoundedEvenWithoutWrongProofs() {
        var limiter = NumericPairingRequestLimiter()
        for _ in 0..<3 { XCTAssertTrue(limiter.admitRequest(at: 0)) }
        XCTAssertFalse(limiter.admitRequest(at: 0))
        XCTAssertFalse(limiter.admitRequest(at: 59.9))
        XCTAssertTrue(limiter.admitRequest(at: 60))
    }

    func testLeadingZeroCodesAndStrictWireEnvelope() throws {
        XCTAssertTrue(NumericPairingCode.isValid(String(format: "%04d", 7)))
        XCTAssertFalse(NumericPairingCode.isValid("１２３４"))
        let code = NumericPairingCode.generate()
        XCTAssertTrue(NumericPairingCode.isValid(code))
        XCTAssertFalse(NumericPairingCode.isValid(code + "0"))
        var packet = NumericPairingMessage(id: UUID(), phase: .request)
        packet.serviceName = UUID().uuidString
        packet.name = "Test Phone"
        let message = WireMessage(type: .pairing, pairing: packet)
        XCTAssertEqual(try WireCodec.decode(WireCodec.encode(message)), message)
        var invalid = message
        invalid.authToken = try PairingSecurity.randomToken()
        XCTAssertThrowsError(try invalid.validate())
        invalid = message
        invalid.type = .authenticate
        XCTAssertThrowsError(try invalid.validate())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: WireCodec.encode(message)) as? [String: Any])
        var payload = try XCTUnwrap(object["pairing"] as? [String: Any])
        payload["pin"] = code
        object["pairing"] = payload
        XCTAssertThrowsError(try WireCodec.decode(JSONSerialization.data(withJSONObject: object)))
        packet.publicKey = Data(repeating: 1, count: 384)
        XCTAssertThrowsError(
            try packet.validate(), "An otherwise valid field is forbidden in the wrong phase.")
    }
}
