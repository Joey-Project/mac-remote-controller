import Foundation
import XCTest
@testable import AppleCore

@MainActor
final class NumericPairingCoordinatorTests: XCTestCase {
    @MainActor
    private final class Harness {
        let identity = NumericPairingMacIdentity(
            serviceName: UUID().uuidString, name: "Test Mac",
            certificateSHA256: PairingSecurity.fingerprint(Data("test certificate".utf8)))
        let request = UUID()
        let connection = UUID()
        var now = 0.0
        var unlocked = true
        var coordinator: NumericPairingCoordinator!
        var snapshot: NumericPairingRequest?
        var sent: [(UUID, NumericPairingMessage)] = []
        var authorized: [(UUID, String)] = []
        var closed: [UUID] = []

        init() {
            coordinator = NumericPairingCoordinator(
                identity: identity,
                isUnlocked: { [weak self] in self?.unlocked == true },
                now: { [weak self] in self?.now ?? 0 })
            coordinator.onSend = { [weak self] in self?.sent.append(($0, $1)) }
            coordinator.onChange = { [weak self] in self?.snapshot = $0 }
            coordinator.onAuthorize = { [weak self] in self?.authorized.append(($0, $1)) }
            coordinator.onClose = { [weak self] in self?.closed.append($0) }
        }

        func start(request: UUID? = nil, connection: UUID? = nil) {
            var packet = NumericPairingMessage(id: request ?? self.request, phase: .request)
            packet.serviceName = identity.serviceName
            packet.name = "Test Phone"
            coordinator.receive(packet, from: connection ?? self.connection)
        }

        func send(_ packet: NumericPairingMessage) { coordinator.receive(packet, from: connection) }

        func wait(for phase: NumericPairingPhase, after count: Int) async throws
            -> NumericPairingMessage
        {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let packet = sent.dropFirst(count).last(where: { $0.1.phase == phase })?.1 {
                    return packet
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw NumericPairingFailure.expired
        }

        func attempt(code: String) async throws -> (NumericPairingClientCrypto, Int) {
            let (client, proof) = try await prepareProof(code: code)
            let count = sent.count
            send(proof)
            return (client, count)
        }

        func prepareProof(code: String) async throws
            -> (NumericPairingClientCrypto, NumericPairingMessage)
        {
            let client = NumericPairingClientCrypto(requestID: request)
            var hello = NumericPairingMessage(id: request, phase: .hello)
            hello.publicKey = try await client.begin(code: code)
            let count = sent.count
            send(hello)
            let challenge = try await wait(for: .challenge, after: count)
            let attempt = try XCTUnwrap(challenge.attemptID)
            let context = NumericPairingContext(
                requestID: request, attemptID: attempt,
                serviceName: identity.serviceName, certificateSHA256: identity.certificateSHA256,
                deviceName: "Test Phone", macName: identity.name)
            let response = try await client.answer(
                NumericPairingChallenge(
                    salt: XCTUnwrap(challenge.salt), publicKey: XCTUnwrap(challenge.publicKey)),
                context: context)
            var proof = NumericPairingMessage(id: request, phase: .proof)
            proof.attemptID = attempt
            proof.proof = response.proof
            proof.binding = response.binding
            return (client, proof)
        }
    }

    func testOnlyVerifiedFinishCanAuthorizeTheOwningConnection() async throws {
        let harness = Harness()
        harness.start()
        let code = try XCTUnwrap(harness.snapshot?.code)
        let (client, count) = try await harness.attempt(code: code)
        let accepted = try await harness.wait(for: .accepted, after: count)
        XCTAssertTrue(harness.authorized.isEmpty, "A client proof alone cannot save credentials.")
        let binding = try await client.accept(
            NumericPairingProof(
                proof: XCTUnwrap(accepted.proof), binding: XCTUnwrap(accepted.binding)))
        var finish = NumericPairingMessage(id: harness.request, phase: .finish)
        finish.attemptID = accepted.attemptID
        finish.binding = binding
        harness.send(finish)
        let deadline = ContinuousClock.now + .seconds(5)
        while harness.authorized.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.authorized.count, 1)
        XCTAssertEqual(harness.authorized.first?.0, harness.connection)
        XCTAssertNil(harness.snapshot)
        harness.send(finish)
        XCTAssertEqual(harness.authorized.count, 1, "A replay cannot create another credential.")
    }

    func testThirdWrongAttemptClosesCodeAndReplacementCannotEvadeGlobalLimit() async throws {
        let harness = Harness()
        harness.start()
        let code = try XCTUnwrap(harness.snapshot?.code)
        let wrong = (code.first == "0" ? "1" : "0") + String(code.dropFirst())
        for remaining in stride(from: 2, through: 0, by: -1) {
            let (_, count) = try await harness.attempt(code: wrong)
            let phase: NumericPairingPhase = remaining > 0 ? .retry : .rejected
            let response = try await harness.wait(for: phase, after: count)
            if remaining > 0 {
                XCTAssertEqual(response.remainingAttempts, remaining)
            } else {
                XCTAssertEqual(response.failure, .tooManyAttempts)
            }
        }
        XCTAssertNil(harness.snapshot)
        XCTAssertTrue(harness.authorized.isEmpty)
        harness.start(request: UUID(), connection: UUID())
        XCTAssertEqual(harness.sent.last?.1.failure, .tooManyAttempts)
        harness.now = 61
        harness.start(request: UUID(), connection: UUID())
        XCTAssertNotNil(harness.snapshot)
        XCTAssertNotEqual(harness.snapshot?.code, code)
    }

    func testBusyForeignCancelAndExpiryNeverAuthorize() {
        let harness = Harness()
        harness.start()
        let original = harness.snapshot
        harness.start(request: UUID(), connection: UUID())
        XCTAssertEqual(harness.sent.last?.1.failure, .busy)
        harness.coordinator.receive(
            NumericPairingMessage(id: harness.request, phase: .cancel), from: UUID())
        XCTAssertEqual(harness.snapshot, original)
        harness.now = 120
        harness.coordinator.tick()
        XCTAssertEqual(harness.sent.last?.1.failure, .expired)
        XCTAssertNil(harness.snapshot)
        XCTAssertTrue(harness.authorized.isEmpty)
    }

    func testMacLockAndTransportDisconnectDiscardPendingRequest() {
        let harness = Harness()
        harness.start()
        harness.unlocked = false
        harness.coordinator.tick()
        XCTAssertNil(harness.snapshot)
        XCTAssertEqual(harness.sent.last?.1.failure, .unavailable)
        harness.unlocked = true
        harness.start()
        harness.coordinator.disconnected(harness.connection)
        XCTAssertNil(harness.snapshot)
        XCTAssertFalse(harness.coordinator.ownsConnection(harness.connection))
        XCTAssertTrue(harness.authorized.isEmpty)
    }

    func testProofExpiringDuringVerificationDoesNotConsumeGlobalFailureBudget() async throws {
        let harness = Harness()
        harness.start()
        let code = try XCTUnwrap(harness.snapshot?.code)
        let wrong = (code.first == "0" ? "1" : "0") + String(code.dropFirst())
        harness.now = 119
        for _ in 0..<2 {
            let (_, count) = try await harness.attempt(code: wrong)
            _ = try await harness.wait(for: .retry, after: count)
        }
        let (_, proof) = try await harness.prepareProof(code: wrong)
        let count = harness.sent.count
        harness.send(proof)
        // The main actor cannot run the verification task until this test yields.
        harness.now = 120
        let rejected = try await harness.wait(for: .rejected, after: count)
        XCTAssertEqual(rejected.failure, .expired)
        XCTAssertNil(harness.coordinator.activeConnectionID)
        XCTAssertTrue(harness.authorized.isEmpty)
        harness.start(request: UUID(), connection: UUID())
        XCTAssertNotNil(harness.snapshot, "Expiry must not charge a third global incorrect guess")
        XCTAssertNotEqual(harness.snapshot?.code, code)
    }
}
