import Foundation
import XCTest

@testable import AppleCore

final class BLETransportSecurityTests: XCTestCase {
    private var token: String {
        Data(repeating: 0x42, count: 32).base64EncodedString()
    }

    func testHandshakeAuthenticatesBothSidesAndDerivesDirectionalKeys() throws {
        var client = try BLEHandshake.Client(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d", deviceName: "Fixture iPhone",
            token: token)
        var server = BLEHandshake.Server(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d",
            pairedTokens: [(id: "fixture-device", token: token)])
        let hello = try client.hello()
        let helloText = try XCTUnwrap(String(data: hello, encoding: .utf8))
        XCTAssertFalse(helloText.contains(token))
        XCTAssertThrowsError(try client.hello()) {
            XCTAssertEqual($0 as? BLETransportError, .invalidHandshake)
        }
        var secondClient = try BLEHandshake.Client(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d", deviceName: "Fixture iPhone",
            token: token)
        XCTAssertNotEqual(hello, try secondClient.hello())
        let challenge = try server.challenge(to: hello)
        XCTAssertThrowsError(try server.challenge(to: hello)) {
            XCTAssertEqual($0 as? BLETransportError, .invalidHandshake)
        }
        let clientFinish = try client.finish(after: challenge)
        XCTAssertThrowsError(try client.finish(after: challenge)) {
            XCTAssertEqual($0 as? BLETransportError, .invalidHandshake)
        }
        let serverFinish = try server.finish(clientFinish.message)
        XCTAssertThrowsError(try server.finish(clientFinish.message)) {
            XCTAssertEqual($0 as? BLETransportError, .invalidHandshake)
        }
        XCTAssertEqual(serverFinish.deviceID, "fixture-device")
        XCTAssertEqual(serverFinish.deviceName, "Fixture iPhone")

        var clientSession = clientFinish.session
        var serverSession = serverFinish.session
        let requestID = UUID().uuidString
        let ping = WireMessage(
            type: .ping, connectionID: UUID().uuidString, requestID: requestID, sequence: 1)
        let encrypted = try clientSession.seal(ping)
        XCTAssertEqual(try serverSession.open(encrypted), ping)
        XCTAssertThrowsError(try clientSession.open(encrypted))

        let pong = WireMessage(
            type: .pong, connectionID: ping.connectionID, requestID: requestID, sequence: 1)
        let encryptedPong = try serverSession.seal(pong)
        XCTAssertEqual(try clientSession.open(encryptedPong), pong)
    }

    func testHandshakeRejectsWrongSecretAndTampering() throws {
        let wrongToken = Data(repeating: 0x24, count: 32).base64EncodedString()
        var client = try BLEHandshake.Client(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d", deviceName: "Fixture iPhone",
            token: token)
        var wrongServer = BLEHandshake.Server(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d",
            pairedTokens: [(id: "fixture-device", token: wrongToken)])
        XCTAssertThrowsError(try wrongServer.challenge(to: client.hello())) {
            XCTAssertEqual($0 as? BLETransportError, .authenticationFailed)
        }

        var validClient = try BLEHandshake.Client(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d", deviceName: "Fixture iPhone",
            token: token)
        var server = BLEHandshake.Server(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d",
            pairedTokens: [(id: "fixture-device", token: token)])
        var challenge = try server.challenge(to: validClient.hello())
        var challengeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: challenge.dropFirst()) as? [String: Any])
        var proof = try XCTUnwrap(challengeJSON["proof"] as? String)
        let proofIndex = proof.index(before: proof.endIndex)
        proof.replaceSubrange(proofIndex...proofIndex, with: proof[proofIndex] == "A" ? "B" : "A")
        challengeJSON["proof"] = proof
        challenge = Data([0x01]) + (try JSONSerialization.data(withJSONObject: challengeJSON))
        XCTAssertThrowsError(try validClient.finish(after: challenge)) {
            XCTAssertEqual($0 as? BLETransportError, .authenticationFailed)
        }
    }

    func testEncryptedFramesRejectReplayTamperReorderAndWrongDirection() throws {
        var client = try BLEHandshake.Client(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d", deviceName: "Fixture iPhone",
            token: token)
        var server = BLEHandshake.Server(
            serviceName: "a4c8c497-a6f7-4b35-94fb-b0b735aa0e2d",
            pairedTokens: [(id: "fixture-device", token: token)])
        let challenge = try server.challenge(to: client.hello())
        let finish = try client.finish(after: challenge)
        let serverFinish = try server.finish(finish.message)
        var clientSession = finish.session
        var serverSession = serverFinish.session
        let message = WireMessage(
            type: .ping, connectionID: UUID().uuidString, requestID: UUID().uuidString, sequence: 1)
        let frame = try clientSession.seal(message)
        let nextMessage = WireMessage(
            type: .ping, connectionID: message.connectionID, requestID: UUID().uuidString,
            sequence: 2)
        let nextFrame = try clientSession.seal(nextMessage)
        XCTAssertThrowsError(try serverSession.open(nextFrame)) {
            XCTAssertEqual($0 as? BLETransportError, .replayOrOutOfOrder)
        }
        var tampered = frame
        tampered[tampered.count - 1] ^= 0x80
        XCTAssertThrowsError(try serverSession.open(tampered)) {
            XCTAssertEqual($0 as? BLETransportError, .authenticationFailed)
        }
        XCTAssertEqual(try serverSession.open(frame), message)
        XCTAssertEqual(try serverSession.open(nextFrame), nextMessage)
        XCTAssertThrowsError(try serverSession.open(frame)) {
            XCTAssertEqual($0 as? BLETransportError, .replayOrOutOfOrder)
        }
        XCTAssertThrowsError(try clientSession.open(frame))
        XCTAssertThrowsError(
            try serverSession.open(
                Data(repeating: 0x02, count: BLEFrameCodec.maximumPayloadBytes + 1)))
    }

    func testFrameDecoderReassemblesFragmentsAndBoundsBuffer() throws {
        let payload = Data(repeating: 0x31, count: 128)
        let frame = try BLEFrameCodec.encode(payload)
        var decoder = BLEFrameDecoder()
        XCTAssertTrue(try decoder.append(frame.prefix(3)).isEmpty)
        XCTAssertEqual(try decoder.append(frame.dropFirst(3)), [payload])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
        XCTAssertThrowsError(
            try decoder.append(Data(repeating: 0, count: BLEFrameCodec.maximumPayloadBytes + 5))
        ) {
            XCTAssertEqual($0 as? BLETransportError, .oversizedFrame)
        }
    }

    func testBenchmarkReportsPercentilesTimeoutsBoundsAndCancellation() {
        var benchmark = RTTBenchmarkAccumulator(
            transport: "BLE", groups: 1, samplesPerGroup: 4, warmupCount: 1)
        benchmark.record(roundTripNanoseconds: 99)
        benchmark.record(roundTripNanoseconds: 1_000_000)
        benchmark.record(roundTripNanoseconds: 2_000_000)
        benchmark.record(roundTripNanoseconds: nil)
        benchmark.record(roundTripNanoseconds: 4_000_000)
        XCTAssertTrue(benchmark.isComplete)
        let report = benchmark.report()
        XCTAssertEqual(report.successfulRoundTripsNanoseconds.count, 3)
        XCTAssertEqual(report.timeoutCount, 1)
        XCTAssertEqual(report.lossRate, 0.25)
        XCTAssertEqual(report.minimumMilliseconds, 1)
        XCTAssertEqual(report.medianMilliseconds, 2)
        XCTAssertEqual(report.p95Milliseconds, 4)
        XCTAssertEqual(report.jitterMilliseconds, 2)

        var cancelled = RTTBenchmarkAccumulator(transport: "Wi-Fi")
        cancelled.cancel()
        XCTAssertTrue(cancelled.report().cancelled)

        let bounded = RTTBenchmarkAccumulator(
            transport: "BLE", groups: .max, samplesPerGroup: .max, warmupCount: .max)
        XCTAssertEqual(bounded.groups, RTTBenchmarkAccumulator.maximumGroups)
        XCTAssertEqual(bounded.samplesPerGroup, RTTBenchmarkAccumulator.maximumSamplesPerGroup)
        XCTAssertEqual(bounded.warmupCount, RTTBenchmarkAccumulator.maximumWarmupCount)
        XCTAssertEqual(bounded.report().expectedAttemptCount, 500)
    }
}
