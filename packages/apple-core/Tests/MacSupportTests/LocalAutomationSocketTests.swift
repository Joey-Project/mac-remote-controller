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
            let server = server(url)
            try server.start()
            defer { server.stop() }
            let deadline = ContinuousClock.now + .seconds(5)
            let descriptor = try LocalAutomationSocket.connect(url, deadline: deadline)
            defer { close(descriptor) }
            XCTAssertEqual(
                try LocalAutomationClient.send(.init(.status), to: url).outcome, .success)
            XCTAssertThrowsError(
                try LocalAutomationSocket.readFrame(descriptor, limit: 65536, deadline: deadline))
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
