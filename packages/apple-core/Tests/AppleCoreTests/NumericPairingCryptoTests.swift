import Foundation
import XCTest
@testable import AppleCore

@MainActor
final class NumericPairingCryptoTests: XCTestCase {
    private func context(
        requestID: UUID, attemptID: UUID = UUID(), certificate: String = "test certificate",
        service: String = "00000000-0000-4000-8000-000000000001", phone: String = "Test Phone"
    ) -> NumericPairingContext {
        NumericPairingContext(
            requestID: requestID, attemptID: attemptID, serviceName: service,
            certificateSHA256: PairingSecurity.fingerprint(Data(certificate.utf8)),
            deviceName: phone, macName: "Test Mac")
    }

    func testCorrectCodeMutuallyAuthenticatesAndFinishIsSingleUse() async throws {
        let id = UUID()
        let code = NumericPairingCode.generate()
        let client = NumericPairingClientCrypto(requestID: id)
        let server = try NumericPairingServerCrypto(requestID: id, code: code)
        let context = context(requestID: id)
        let publicKey = try await client.begin(code: code)
        let challenge = try await server.challenge(clientPublicKey: publicKey, context: context)
        let clientProof = try await client.answer(challenge, context: context)
        let serverProof = try await server.verify(clientProof)
        let finish = try await client.accept(serverProof)
        try await server.finish(finish)
        do {
            try await server.finish(finish)
            XCTFail("A completed exchange must not authorize another device.")
        } catch {}
        do {
            _ = try await client.accept(serverProof)
            XCTFail("A server proof is single-use.")
        } catch {}
    }

    func testWrongCodeCannotAuthenticateAndRetryUsesFreshKeys() async throws {
        let id = UUID()
        let code = NumericPairingCode.generate()
        let wrong = (code.first == "0" ? "1" : "0") + String(code.dropFirst())
        let client = NumericPairingClientCrypto(requestID: id)
        let server = try NumericPairingServerCrypto(requestID: id, code: code)
        let first = context(requestID: id)
        let firstKey = try await client.begin(code: wrong)
        let firstChallenge = try await server.challenge(clientPublicKey: firstKey, context: first)
        let wrongProof = try await client.answer(firstChallenge, context: first)
        do {
            _ = try await server.verify(wrongProof)
            XCTFail("An incorrect code cannot produce a server proof.")
        } catch {}

        let next = context(requestID: id)
        let nextKey = try await client.begin(code: code)
        let nextChallenge = try await server.challenge(clientPublicKey: nextKey, context: next)
        XCTAssertNotEqual(firstKey, nextKey)
        XCTAssertNotEqual(firstChallenge.publicKey, nextChallenge.publicKey)
        let response = try await client.answer(nextChallenge, context: next)
        let serverProof = try await server.verify(response)
        let finish = try await client.accept(serverProof)
        try await server.finish(finish)
    }

    func testRelayedProofCannotChangeTLSCertificateServiceOrDeviceName() async throws {
        for variation in 0..<3 {
            let id = UUID()
            let attempt = UUID()
            let code = NumericPairingCode.generate()
            let serverContext = context(requestID: id, attemptID: attempt)
            let clientContext = context(
                requestID: id, attemptID: attempt,
                certificate: variation == 0 ? "impostor certificate" : "test certificate",
                service: variation == 1
                    ? "00000000-0000-4000-8000-000000000002" : serverContext.serviceName,
                phone: variation == 2 ? "Other Phone" : "Test Phone")
            let client = NumericPairingClientCrypto(requestID: id)
            let server = try NumericPairingServerCrypto(requestID: id, code: code)
            let publicKey = try await client.begin(code: code)
            let challenge = try await server.challenge(
                clientPublicKey: publicKey, context: serverContext)
            let proof = try await client.answer(challenge, context: clientContext)
            do {
                _ = try await server.verify(proof)
                XCTFail("A proof cannot be relayed into a different authenticated context.")
            } catch {}
        }
    }

    func testInvalidKeysAndCancelledExchangesCannotComplete() async throws {
        let id = UUID()
        let code = NumericPairingCode.generate()
        let client = NumericPairingClientCrypto(requestID: id)
        let server = try NumericPairingServerCrypto(requestID: id, code: code)
        let context = context(requestID: id)
        for key in [Data(), Data(repeating: 0, count: 384), Data(repeating: 1, count: 385)] {
            do {
                _ = try await server.challenge(clientPublicKey: key, context: context)
                XCTFail("Invalid public keys must fail before modular exponentiation.")
            } catch {}
        }
        let publicKey = try await client.begin(code: code)
        let challenge = try await server.challenge(clientPublicKey: publicKey, context: context)
        await client.cancel()
        do {
            _ = try await client.answer(challenge, context: context)
            XCTFail("Cancellation must discard the pending PIN and ephemeral key.")
        } catch {}
        await server.cancel()
        do {
            try await server.finish(Data(repeating: 0, count: 32))
            XCTFail("Cancellation cannot be completed by a delayed finish.")
        } catch {}
    }
}
