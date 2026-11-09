#if os(macOS)
    import AppleCore
    import Foundation
    import Network
    import Security
    import XCTest

    @MainActor
    final class NumericPairingTransportTests: XCTestCase {
        func testEnrollmentRecordsActualTLSLeafBeforeSendingItsRequest() async throws {
            guard #available(macOS 15, *) else {
                throw XCTSkip("Memory-only TLS identity import requires macOS 15")
            }
            let identity = try MemoryOnlyTLSIdentity.make()
            let loopback = try PairingLoopback(identity: identity.identity)
            defer { loopback.stop() }
            let received = expectation(description: "pairing request reaches TLS server")
            var observed: String?
            loopback.onMessage = { message in
                XCTAssertEqual(message.type, .pairing)
                XCTAssertEqual(message.pairing?.phase, .request)
                XCTAssertNil(message.authToken)
                received.fulfill()
            }
            try await loopback.connect(
                parameters: WebSocketPeer.parameters(onPairingCertificate: { observed = $0 }),
                onReady: { peer in
                    XCTAssertEqual(observed, identity.fingerprint)
                    var packet = NumericPairingMessage(id: UUID(), phase: .request)
                    packet.serviceName = UUID().uuidString
                    packet.name = "Isolated TLS test"
                    peer.send(WireMessage(type: .pairing, pairing: packet))
                })
            await fulfillment(of: [received], timeout: 5)
            XCTAssertEqual(observed, identity.fingerprint, loopback.diagnostics)
        }

        func testPairingCallbackCannotWeakenAnExistingCertificatePin() async throws {
            guard #available(macOS 15, *) else {
                throw XCTSkip("Memory-only TLS identity import requires macOS 15")
            }
            let identity = try MemoryOnlyTLSIdentity.make()
            let loopback = try PairingLoopback(identity: identity.identity)
            defer { loopback.stop() }
            let rejected = expectation(description: "wrong pin rejects TLS")
            // A fresh digest represents a different public certificate, not a saved credential.
            let wrongPin = PairingSecurity.fingerprint(Data(UUID().uuidString.utf8))
            try await loopback.connect(
                parameters: WebSocketPeer.parameters(
                    pin: wrongPin, onTrustFailure: { rejected.fulfill() },
                    onPairingCertificate: { _ in XCTFail("Pinned connection became provisional") }),
                onReady: { _ in XCTFail("Incorrect certificate pin was accepted") })
            await fulfillment(of: [rejected], timeout: 5)
        }
    }

    /// No Bonjour publication, app identity, saved credential or Keychain access.
    @MainActor
    private final class PairingLoopback {
        var onMessage: ((WireMessage) -> Void)?
        private let listener: NWListener
        private var server: WebSocketPeer?
        private var client: WebSocketPeer?
        private var serverConnection: NWConnection?
        private var clientConnection: NWConnection?
        var diagnostics: String {
            [
                "listener=\(listener.state)",
                "server=\(String(describing: serverConnection?.state))",
                "client=\(String(describing: clientConnection?.state))"
            ].joined(separator: ", ")
        }

        init(identity: SecIdentity) throws {
            let parameters = WebSocketPeer.parameters(identity: identity)
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self else { connection.cancel(); return }
                    let peer = WebSocketPeer(connection: connection)
                    self.serverConnection = connection
                    self.server = peer
                    peer.onMessage = { [weak self] in self?.onMessage?($0) }
                    peer.start()
                }
            }
            listener.start(queue: .main)
        }

        func connect(parameters: NWParameters, onReady: @escaping (WebSocketPeer) -> Void)
            async throws
        {
            let deadline = ContinuousClock.now + .seconds(5)
            while listener.state != .ready, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let port = try XCTUnwrap(listener.port)
            XCTAssertNotEqual(port.rawValue, 0)
            let url = try XCTUnwrap(URL(string: "wss://127.0.0.1:\(port.rawValue)/"))
            let connection = NWConnection(to: .url(url), using: parameters)
            clientConnection = connection
            let peer = WebSocketPeer(connection: connection)
            client = peer
            peer.onReady = { [weak peer] in
                guard let peer else { return }
                onReady(peer)
            }
            peer.start()
        }

        func stop() { client?.close(); server?.close(); listener.cancel() }
    }

    @available(macOS 15, *)
    private struct MemoryOnlyTLSIdentity {
        let identity: SecIdentity
        let fingerprint: String

        static func make() throws -> Self {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sofa-pairing-tls-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let password = UUID().uuidString
            let passwordFile = directory.appendingPathComponent("passphrase")
            try Data(password.utf8).write(to: passwordFile, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: passwordFile.path)
            try openssl(
                [
                    "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=Sofa Remote isolated TLS test", "-keyout", "key.pem",
                    "-out", "certificate.pem"
                ], directory: directory)
            try openssl(
                [
                    "pkcs12", "-export", "-inkey", "key.pem", "-in", "certificate.pem",
                    "-out", "identity.p12", "-passout", "file:\(passwordFile.path)"
                ], directory: directory)
            let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
            let options: [CFString: Any] = [
                kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true
            ]
            var imported: CFArray?
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
            guard status == errSecSuccess,
                let item = (imported as? [[String: Any]])?.first,
                let value = item[kSecImportItemIdentity as String],
                CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
            else { throw TLSFixtureError.importFailed(status) }
            let identity = unsafeDowncast(value as AnyObject, to: SecIdentity.self)
            var certificate: SecCertificate?
            let copyStatus = SecIdentityCopyCertificate(identity, &certificate)
            guard copyStatus == errSecSuccess, let certificate else {
                throw TLSFixtureError.importFailed(copyStatus)
            }
            return Self(
                identity: identity,
                fingerprint: PairingSecurity.fingerprint(
                    SecCertificateCopyData(certificate) as Data))
        }

        private static func openssl(_ arguments: [String], directory: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw TLSFixtureError.opensslFailed }
        }
    }

    private enum TLSFixtureError: Error {
        case importFailed(OSStatus), opensslFailed
    }
#endif
