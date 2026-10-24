import AppleCore
import Darwin
import Foundation
import Network
@testable import MacSupport
import XCTest

@MainActor
final class LoopbackMediaBridgePollRouteTests: XCTestCase {
    func testConsumerCompatiblePollResponses() async throws {
        let fixture = try await LoopbackMediaBridgeHTTPFixture.start()
        defer { fixture.stop(sessionIDs: ["poll-chrome", "poll-iina"]) }
        try await fixture.verifyConsumerCompatiblePollResponses()
    }
}

@MainActor
final class LoopbackMediaBridgeResultRouteTests: XCTestCase {
    func testLateResultCannotChangeOrReplayOtherPendingWork() async throws {
        let fixture = try await LoopbackMediaBridgeHTTPFixture.start()
        defer { fixture.stop(sessionIDs: ["late-chrome", "reused-late-chrome", "current-chrome"]) }
        try await fixture.verifyLateResultHandling()
    }
}

@MainActor
private final class LoopbackMediaBridgeHTTPFixture {
    let bridge: LoopbackMediaBridge
    let configuration: MediaBridgeConfiguration

    private let chromeTarget = MediaTarget(
        id: "chrome:test", name: "Chrome test target", kind: .youtube,
        capabilities: MediaCapabilities(playPause: true, seek: true, next: true, previous: true))
    private let iinaTarget = MediaTarget(
        id: "iina:test", name: "IINA test target", kind: .iina,
        capabilities: MediaCapabilities(playPause: true, seek: true, next: true, previous: true))

    private init(bridge: LoopbackMediaBridge, configuration: MediaBridgeConfiguration) {
        self.bridge = bridge
        self.configuration = configuration
    }

    static func start() async throws -> LoopbackMediaBridgeHTTPFixture {
        let port = try LoopbackMediaBridgeTestPort.allocate()
        let configuration = MediaBridgeTestFixture.configuration(port: port)
        let bridge = LoopbackMediaBridge(configuration: configuration)
        try bridge.start()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !isReady(bridge), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard isReady(bridge), bridge.listeningPort == configuration.port else {
            bridge.stop()
            throw LoopbackMediaBridgeRouteTestError.listenerTimedOut
        }
        return LoopbackMediaBridgeHTTPFixture(bridge: bridge, configuration: configuration)
    }

    func stop(sessionIDs: [String]) {
        bridge.stop()
        for sessionID in sessionIDs { bridge.router.cancel(sessionID: sessionID) }
    }

    func verifyConsumerCompatiblePollResponses() async throws {
        try bridge.router.update(chromeTarget)
        try bridge.router.update(iinaTarget)
        try await assertEmptyPoll(path: "/v1/chrome/next")
        try await assertEmptyPoll(
            path: "/v1/iina/next",
            queryItems: [URLQueryItem(name: "targetId", value: iinaTarget.id)])
        try await assertChromeCommandPoll()
        try await assertIINACommandPoll()
    }

    private func assertEmptyPoll(
        path: String, queryItems: [URLQueryItem] = []
    ) async throws {
        let (data, response) = try await send(
            method: "GET", path: path, queryItems: queryItems)
        XCTAssertEqual(response.statusCode, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), ["command"])
        XCTAssertTrue(envelope["command"] is NSNull)
    }

    private func assertChromeCommandPoll() async throws {
        let requestID = "poll-chrome:1"
        let work = enqueue(
            targetID: chromeTarget.id, action: .playPause,
            requestID: requestID, sessionID: "poll-chrome")
        await Task.yield()
        let (data, response) = try await send(method: "GET", path: "/v1/chrome/next")
        XCTAssertEqual(response.statusCode, 200)
        let command = try commandObject(from: data, keys: ["requestId", "targetId", "action"])
        XCTAssertEqual(command["requestId"] as? String, requestID)
        XCTAssertEqual(command["targetId"] as? String, chromeTarget.id)
        XCTAssertEqual(command["action"] as? String, "playPause")
        XCTAssertNil(command["value"])
        XCTAssertEqual(
            try decodeCommand(command),
            RoutedMediaCommand(
                requestID: requestID, targetID: chromeTarget.id, action: .playPause, value: nil))
        XCTAssertTrue(bridge.router.complete(requestID: requestID, targetID: chromeTarget.id))
        try await work.value
    }

    private func assertIINACommandPoll() async throws {
        let requestID = "poll-iina:1"
        let work = enqueue(
            targetID: iinaTarget.id, action: .seek, value: -12,
            requestID: requestID, sessionID: "poll-iina")
        await Task.yield()
        let (data, response) = try await send(
            method: "GET", path: "/v1/iina/next",
            queryItems: [URLQueryItem(name: "targetId", value: iinaTarget.id)])
        XCTAssertEqual(response.statusCode, 200)
        let command = try commandObject(
            from: data, keys: ["requestId", "targetId", "action", "value"])
        XCTAssertEqual(command["requestId"] as? String, requestID)
        XCTAssertEqual(command["targetId"] as? String, iinaTarget.id)
        XCTAssertEqual(command["action"] as? String, "seek")
        XCTAssertEqual(command["value"] as? Double, -12)
        XCTAssertEqual(
            try decodeCommand(command),
            RoutedMediaCommand(
                requestID: requestID, targetID: iinaTarget.id, action: .seek, value: -12))
        XCTAssertTrue(bridge.router.complete(requestID: requestID, targetID: iinaTarget.id))
        try await work.value
    }

    func verifyLateResultHandling() async throws {
        try bridge.router.update(chromeTarget)
        let lateID = "late-chrome:1"
        let lateWork = enqueue(
            targetID: chromeTarget.id, action: .next,
            requestID: lateID, sessionID: "late-chrome")
        await Task.yield()
        XCTAssertEqual(bridge.router.takeNext(targetID: chromeTarget.id)?.requestID, lateID)
        try await assertAdapterTimeout(lateWork)
        XCTAssertNil(bridge.router.takeNext(targetID: chromeTarget.id))
        try await assertRetiredIDCannotBeReused(lateID)

        let currentID = "current-chrome:1"
        let currentWork = enqueue(
            targetID: chromeTarget.id, action: .playPause,
            requestID: currentID, sessionID: "current-chrome")
        await Task.yield()
        try await assertRejectedResultsDoNotCompleteCurrentWork(currentID)
        try await assertLateResultAcknowledged(lateID)
        try await assertCurrentResultCompletes(currentID, work: currentWork)
    }

    private func assertAdapterTimeout(_ work: Task<Void, Error>) async throws {
        do {
            try await work.value
            XCTFail("delivered work without a result must time out")
        } catch {
            XCTAssertEqual(error as? MediaRouteError, .adapter("The media player did not respond."))
        }
    }

    private func assertRetiredIDCannotBeReused(_ requestID: String) async throws {
        do {
            try await bridge.router.execute(
                MediaRequest(targetID: chromeTarget.id, action: .next),
                requestID: requestID, sessionID: "reused-late-chrome")
            XCTFail("a retired request ID must not be reused")
        } catch let error as WireProtocolError {
            guard case .invalidCommand = error else {
                return XCTFail("unexpected request ID reuse error: \(error)")
            }
        }
    }

    private func assertRejectedResultsDoNotCompleteCurrentWork(_ requestID: String) async throws {
        let early = try await postChromeResult(
            requestID: requestID, targetID: chromeTarget.id, succeeded: false,
            error: "premature result", configuration: configuration)
        XCTAssertEqual(early.statusCode, 400)
        XCTAssertEqual(bridge.router.takeNext(targetID: chromeTarget.id)?.requestID, requestID)

        let wrongRoute = try await postIINAResult(
            requestID: requestID, targetID: chromeTarget.id, succeeded: false,
            configuration: configuration)
        XCTAssertEqual(wrongRoute.statusCode, 400)
        let wrongTarget = try await postChromeResult(
            requestID: requestID, targetID: "chrome:other", succeeded: false,
            error: "wrong target", configuration: configuration)
        XCTAssertEqual(wrongTarget.statusCode, 400)
        let unknown = try await postChromeResult(
            requestID: "unknown-request", targetID: chromeTarget.id, succeeded: false,
            error: "unknown request", configuration: configuration)
        XCTAssertEqual(unknown.statusCode, 400)
    }

    private func assertLateResultAcknowledged(_ requestID: String) async throws {
        let first = try await postChromeResult(
            requestID: requestID, targetID: chromeTarget.id, succeeded: false,
            error: "The browser tab did not respond.", configuration: configuration)
        XCTAssertEqual(first.statusCode, 204)
        let duplicate = try await postChromeResult(
            requestID: requestID, targetID: chromeTarget.id, succeeded: false,
            error: "The browser tab did not respond.", configuration: configuration)
        XCTAssertEqual(duplicate.statusCode, 204)
    }

    private func assertCurrentResultCompletes(
        _ requestID: String, work: Task<Void, Error>
    ) async throws {
        let response = try await postChromeResult(
            requestID: requestID, targetID: chromeTarget.id, succeeded: true,
            configuration: configuration)
        XCTAssertEqual(response.statusCode, 204)
        try await work.value
    }

    private func enqueue(
        targetID: String,
        action: MediaAction,
        value: Double? = nil,
        requestID: String,
        sessionID: String
    ) -> Task<Void, Error> {
        Task {
            try await bridge.router.execute(
                MediaRequest(targetID: targetID, action: action, value: value),
                requestID: requestID, sessionID: sessionID)
        }
    }
}

private extension LoopbackMediaBridgeHTTPFixture {
    func commandObject(from data: Data, keys: Set<String>) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(envelope.keys), ["command"])
        let command = try XCTUnwrap(envelope["command"] as? [String: Any])
        XCTAssertEqual(Set(command.keys), keys)
        return command
    }

    func decodeCommand(_ command: [String: Any]) throws -> RoutedMediaCommand {
        let data = try JSONSerialization.data(withJSONObject: command)
        return try JSONDecoder().decode(RoutedMediaCommand.self, from: data)
    }

    func send(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String = "application/json",
        configuration: MediaBridgeConfiguration? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let configuration = configuration ?? self.configuration
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(configuration.port)
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        let url = try XCTUnwrap(components.url)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LoopbackMediaBridgeRouteTestError.invalidResponse
        }
        return (data, response)
    }

    func postChromeResult(
        requestID: String,
        targetID: String,
        succeeded: Bool,
        error: String? = nil,
        configuration: MediaBridgeConfiguration
    ) async throws -> HTTPURLResponse {
        var body: [String: Any] = [
            "type": "media.commandResult", "requestId": requestID,
            "targetId": targetID, "ok": succeeded
        ]
        if let error { body["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(
            method: "POST", path: "/v1/chrome", body: data,
            configuration: configuration
        ).1
    }

    func postIINAResult(
        requestID: String,
        targetID: String,
        succeeded: Bool,
        configuration: MediaBridgeConfiguration
    ) async throws -> HTTPURLResponse {
        let body: [String: Any] = [
            "requestId": requestID, "targetId": targetID, "ok": succeeded
        ]
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payload = try XCTUnwrap(String(data: json, encoding: .utf8))
        let encodedPayload = try XCTUnwrap(
            payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        return try await send(
            method: "POST", path: "/v1/iina/result",
            body: Data("payload=\(encodedPayload)".utf8),
            contentType: IINAFormPayload.contentType,
            configuration: configuration
        ).1
    }
}

enum MediaBridgeTestFixture {
    static func configuration(port: UInt16) -> MediaBridgeConfiguration {
        // Synthetic bearer fixture: bearer-a (joey-private-v3).
        MediaBridgeConfiguration(port: port, token: "codex_synth_v1_bearer_a")
    }
}

private enum LoopbackMediaBridgeTestPort {
    static func allocate() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackMediaBridgeRouteTestError.portUnavailable }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LoopbackMediaBridgeRouteTestError.portUnavailable }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else { throw LoopbackMediaBridgeRouteTestError.portUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}

private enum LoopbackMediaBridgeRouteTestError: Error {
    case invalidResponse
    case listenerTimedOut
    case portUnavailable
}

@MainActor
private func isReady(_ bridge: LoopbackMediaBridge) -> Bool {
    guard let listener = bridge.listener else { return false }
    if case .ready = listener.state { return true }
    return false
}
