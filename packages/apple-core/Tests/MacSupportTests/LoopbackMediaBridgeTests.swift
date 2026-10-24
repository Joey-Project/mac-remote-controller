import Foundation
import Darwin
import Network
@testable import MacSupport
import XCTest

@MainActor
final class LoopbackMediaBridgeTests: XCTestCase {
    func testSilentAndPartialRequestsExpireAndRestoreConnectionCapacity() async throws {
        // Synthetic bearer fixture: bearer-a (joey-private-v3).
        let configuration = MediaBridgeConfiguration(
            port: try availableLoopbackPort(), token: "codex_synth_v1_bearer_a")
        let bridge = LoopbackMediaBridge(configuration: configuration)
        try bridge.start()
        var clients: [NWConnection] = []
        defer {
            bridge.stop()
            clients.forEach { $0.cancel() }
        }
        try await waitFor("listener readiness") {
            bridge.listeningPort == configuration.port
        }

        let listenerPort = try XCTUnwrap(NWEndpoint.Port(rawValue: configuration.port))
        for index in 0..<8 {
            let connection = makeConnection(port: listenerPort)
            clients.append(connection)
            connection.start(queue: .main)
            if index.isMultiple(of: 2) == false {
                connection.send(
                    content: Data("GET /".utf8), completion: .contentProcessed { _ in })
            }
        }
        try await waitFor("eight half-open connections") { bridge.activeConnections == 8 }

        let expiredSockets = expectation(description: "the bridge closes expired sockets")
        expiredSockets.expectedFulfillmentCount = 8
        for client in clients {
            client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { expiredSockets.fulfill() }
            }
        }
        await fulfillment(of: [expiredSockets], timeout: 5)
        try await waitFor("deadline cleanup", timeout: .seconds(5)) {
            bridge.activeConnections == 0
        }

        for _ in 0..<8 {
            let connection = makeConnection(port: listenerPort)
            clients.append(connection)
            connection.start(queue: .main)
        }
        try await waitFor("full capacity after cleanup") { bridge.activeConnections == 8 }

        bridge.stop()
        XCTAssertEqual(bridge.activeConnections, 0)
    }

    private func makeConnection(port: NWEndpoint.Port) -> NWConnection {
        NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
    }

    private func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackMediaBridgeTestError.socketUnavailable }
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
        guard bindResult == 0 else { throw LoopbackMediaBridgeTestError.socketUnavailable }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else { throw LoopbackMediaBridgeTestError.socketUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }

    private func waitFor(
        _ label: String,
        timeout: Duration = .seconds(5),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else { throw LoopbackMediaBridgeTestError.timedOut(label) }
    }

}

private enum LoopbackMediaBridgeTestError: Error {
    case socketUnavailable
    case timedOut(String)
}
