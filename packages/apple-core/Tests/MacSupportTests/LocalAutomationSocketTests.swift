#if os(macOS)
    import Darwin
    import XCTest
    @testable import MacSupport

    final class LocalAutomationSocketTests: XCTestCase {
        private func endpoint() throws -> URL {
            let folder = URL(fileURLWithPath: "/tmp/sra-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            return folder.appendingPathComponent("control.sock")
        }

        private func server(_ url: URL) -> LocalAutomationServer {
            LocalAutomationServer(url: url) { request, _ in
                LocalAutomationResponse(.success, values: ["operation": request.operation.rawValue])
            }
        }

        func testRealUnixSocketRoundTripAndPermissions() throws {
            let url = try endpoint()
            let server = server(url)
            try server.start()
            defer { server.stop() }
            XCTAssertEqual(try LocalAutomationSocket.identity(url).st_mode & 0o777, 0o600)
            XCTAssertEqual(
                try LocalAutomationClient.send(.init(.status), to: url).values,
                ["operation": "status"])
            XCTAssertEqual(try LocalAutomationClient.send(.init(.list), to: url).outcome, .success)
        }

        func testASecondListenerCannotTakeOverAnActiveEndpoint() throws {
            let url = try endpoint()
            let first = server(url)
            try first.start()
            defer { first.stop() }
            let second = server(url)
            XCTAssertThrowsError(try second.start())
            XCTAssertEqual(
                try LocalAutomationClient.send(.init(.status), to: url).outcome, .success)
        }

        func testUnsafeDirectoryRegularFileAndSymlinkAreNotChanged() throws {
            let url = try endpoint()
            try Data("keep".utf8).write(to: url)
            XCTAssertThrowsError(try server(url).start())
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
            try FileManager.default.removeItem(at: url)
            let victim = url.deletingLastPathComponent().appendingPathComponent("victim")
            try Data("keep".utf8).write(to: victim)
            try FileManager.default.createSymbolicLink(
                atPath: url.path, withDestinationPath: victim.path)
            XCTAssertThrowsError(try server(url).start())
            XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(chmod(url.deletingLastPathComponent().path, 0o755), 0)
            XCTAssertThrowsError(try server(url).start())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }

        func testAStaleSocketCanBeRecoveredButAReplacementIsNotRemovedOnStop() throws {
            let url = try endpoint()
            let stale = try LocalAutomationSocket.make()
            XCTAssertEqual(
                try LocalAutomationSocket.withAddress(url) { Darwin.bind(stale, $0, $1) }, 0)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            close(stale)
            let server = server(url)
            try server.start()
            XCTAssertEqual(
                try LocalAutomationClient.send(.init(.status), to: url).outcome, .success)
            let moved = url.appendingPathExtension("old")
            try FileManager.default.moveItem(at: url, to: moved)
            try Data("replacement".utf8).write(to: url)
            server.stop()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
        }

        func testOversizedAndMalformedFramesNeverReachTheHandler() throws {
            let url = try endpoint()
            let server = server(url)
            try server.start()
            defer { server.stop() }
            for data in [
                Data(repeating: 65, count: 16385), Data("{bad json}".utf8),
                Data("{}\n{}".utf8)
            ] {
                let deadline = ContinuousClock.now + .seconds(2)
                let descriptor = try LocalAutomationSocket.connect(url, deadline: deadline)
                defer { close(descriptor) }
                try LocalAutomationSocket.writeFrame(data, to: descriptor, deadline: deadline)
                let response = try JSONDecoder().decode(
                    LocalAutomationResponse.self,
                    from: LocalAutomationSocket.readFrame(
                        descriptor, limit: 65536, deadline: deadline))
                XCTAssertEqual(response.outcome, .invalidRequest)
                XCTAssertNil(response.values)
            }
        }

        func testFragmentedFramesAreAssembledWithoutReplayingAnotherRequest() throws {
            let url = try endpoint()
            let server = server(url)
            try server.start()
            defer { server.stop() }
            let deadline = ContinuousClock.now + .seconds(2)
            let descriptor = try LocalAutomationSocket.connect(url, deadline: deadline)
            defer { close(descriptor) }
            let data = try JSONEncoder().encode(LocalAutomationRequest(.list)) + Data([10])
            for byte in data {
                var byte = byte
                XCTAssertEqual(Darwin.write(descriptor, &byte, 1), 1)
            }
            let response = try JSONDecoder().decode(
                LocalAutomationResponse.self,
                from: LocalAutomationSocket.readFrame(descriptor, limit: 65536, deadline: deadline))
            XCTAssertEqual(response.values?["operation"], "list")
        }

        func testIdleClientsExpireAndDoNotBlockNewRequests() throws {
            let url = try endpoint()
            let served = expectation(
                description: "Only the explicit status request reaches the handler")
            served.assertForOverFulfill = true
            let server = LocalAutomationServer(url: url) { request, _ in
                served.fulfill()
                return LocalAutomationResponse(
                    .success, values: ["operation": request.operation.rawValue])
            }
            try server.start()
            defer { server.stop() }
            let deadline = ContinuousClock.now + .seconds(5)
            let descriptor = try LocalAutomationSocket.connect(url, deadline: deadline)
            defer { close(descriptor) }
            XCTAssertEqual(
                try LocalAutomationClient.send(.init(.status), to: url).outcome, .success)
            wait(for: [served], timeout: 1)
            let terminal = try readUntilClosed(descriptor, deadline: deadline)
            if !terminal.isEmpty {
                // An incomplete request may be rejected before the timeout closes its peer.
                let response = try JSONDecoder().decode(
                    LocalAutomationResponse.self, from: terminal)
                XCTAssertEqual(response.outcome, .invalidRequest)
                XCTAssertNil(response.values)
            }
        }

        func testClosureObservationDoesNotAcceptAnOpenIdleSocket() throws {
            let pair = try socketPair()
            XCTAssertThrowsError(
                try readUntilClosed(pair[0], deadline: .now + .milliseconds(50))
            ) {
                XCTAssertEqual($0 as? LocalAutomationFailure, .timedOut)
            }
        }

        func testClosureObservationPreservesARejectionFrameBeforeEOF() throws {
            let pair = try socketPair()
            let frame =
                try JSONEncoder().encode(LocalAutomationResponse(.invalidRequest)) + Data([10])
            try LocalAutomationSocket.writeFrame(
                frame.dropLast(), to: pair[1], deadline: .now + .seconds(1))
            XCTAssertEqual(shutdown(pair[1], SHUT_WR), 0)
            XCTAssertEqual(try readUntilClosed(pair[0], deadline: .now + .seconds(1)), frame)
        }

        private func socketPair() throws -> [Int32] {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw LocalAutomationFailure.unavailable
            }
            let owned = pair
            addTeardownBlock { for descriptor in owned { close(descriptor) } }
            return pair
        }

        /// Observe actual peer closure, rather than mistaking the client's read timeout for expiry.
        private func readUntilClosed(
            _ descriptor: Int32, deadline: ContinuousClock.Instant
        ) throws -> Data {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while ContinuousClock.now < deadline {
                var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&item, 1, 100)
                if result == 0 { continue }
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LocalAutomationFailure.unavailable
                }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 || (count < 0 && errno == ECONNRESET) { return data }
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw LocalAutomationFailure.unavailable
                }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 65536 else { throw LocalAutomationFailure.invalidFrame }
            }
            throw LocalAutomationFailure.timedOut
        }

        func testEncodedFrameLimitsIncludeTheNewlineAndJSONEscaping() throws {
            XCTAssertThrowsError(
                try LocalAutomationSocket.writeFrame(
                    Data(repeating: 65, count: 65536), to: -1, deadline: .now + .seconds(1))
            ) {
                XCTAssertEqual($0 as? LocalAutomationFailure, .invalidFrame)
            }
            let request = LocalAutomationRequest(
                .invoke, control: .recoveryChooseSetup,
                path: "/" + String(repeating: "\u{01}", count: 4090))
            XCTAssertTrue(request.isValid)
            XCTAssertThrowsError(try LocalAutomationClient.send(request)) {
                XCTAssertEqual($0 as? LocalAutomationFailure, .invalidFrame)
            }
        }

        func testConcurrentRestartCannotLoseTheNewEndpointDuringOldCleanup() throws {
            let url = try endpoint()
            for _ in 0..<30 {
                let first = server(url)
                try first.start()
                let stopped = DispatchGroup()
                stopped.enter()
                DispatchQueue.global(qos: .utility).async {
                    first.stop()
                    stopped.leave()
                }
                let next = server(url)
                var started = false
                do { try next.start(); started = true } catch {
                    XCTAssertEqual(error as? LocalAutomationFailure, .alreadyRunning)
                }
                XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
                if !started { try next.start() }
                defer { next.stop() }
                XCTAssertEqual(
                    try LocalAutomationClient.send(.init(.status), to: url).outcome, .success)
            }
        }

        func testAnExistingNonemptyLeaseFileIsPreservedAndRefused() throws {
            let url = try endpoint()
            let lease = url.appendingPathExtension("lock")
            try Data("keep".utf8).write(to: lease)
            XCTAssertEqual(chmod(lease.path, 0o600), 0)
            XCTAssertThrowsError(try server(url).start())
            XCTAssertEqual(try String(contentsOf: lease, encoding: .utf8), "keep")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
#endif
