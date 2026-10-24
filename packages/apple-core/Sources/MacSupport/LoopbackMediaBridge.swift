import AppleCore
import CoreFoundation
import Foundation
import Network
import Security

public struct MediaBridgeConfiguration: Codable, Sendable, Equatable {
    public let port: UInt16
    public let token: String

    public static let defaultPort: UInt16 = 47_623
    public static let fileName = "media-bridge.json"

    public static var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SofaRemote", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func loadOrCreate() throws -> Self {
        let url = configurationURL
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.port > 0, value.token.utf8.count >= 32 else {
                throw MediaBridgeError.invalidConfiguration
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return value
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MediaBridgeError.randomUnavailable
        }
        let configuration = Self(port: defaultPort, token: Data(bytes).base64URLString)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(configuration).write(
            to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return configuration
    }
}

public enum MediaBridgeError: Error, LocalizedError {
    case invalidConfiguration
    case randomUnavailable
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The local media bridge configuration is invalid."
        case .randomUnavailable: "macOS could not create a local media bridge token."
        case .alreadyRunning: "The local media bridge is already running."
        }
    }
}

@MainActor
public final class LoopbackMediaBridge {
    public let configuration: MediaBridgeConfiguration
    public let router: MediaRouter
    public var onTargetsChanged: (([MediaTarget]) -> Void)?
    public var onFailure: ((String) -> Void)?

    var listener: NWListener?
    var activeConnections = 0
    var rateWindow = ContinuousClock.now
    var requestCount = 0

    public init(configuration: MediaBridgeConfiguration, router: MediaRouter = MediaRouter()) {
        self.configuration = configuration
        self.router = router
    }

    public var isRunning: Bool { listener != nil }

    public func start() throws {
        guard listener == nil else { throw MediaBridgeError.alreadyRunning }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw MediaBridgeError.invalidConfiguration
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                if case let .failed(error) = state {
                    self.onFailure?("Local media bridge stopped: \(error.localizedDescription)")
                    listener.cancel()
                    self.listener = nil
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        activeConnections = 0
    }

    public func expireStaleTargets() {
        if !router.expireStaleTargets().isEmpty { onTargetsChanged?(sortedTargets) }
    }

    private func accept(_ connection: NWConnection) {
        guard activeConnections < 8 else {
            connection.cancel()
            return
        }
        activeConnections += 1
        connection.start(queue: .main)
        receive(connection, accumulated: Data(), deadline: DispatchTime.now() + .seconds(3))
    }

    private func receive(_ connection: NWConnection, accumulated: Data, deadline: DispatchTime) {
        let completion: @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void = {
            // This captured callback signature wraps under swift-format's line-length rule.
            // swiftlint:disable:next closure_parameter_position
            [weak self, weak connection] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                if let request = HTTPRequest.parse(bytes) {
                    self.handle(request, on: connection)
                    return
                }
                if error != nil || complete || bytes.count >= 65_536
                    || DispatchTime.now() >= deadline
                {
                    self.send(status: 400, body: ["error": "invalid_request"], on: connection)
                    return
                }
                self.receive(connection, accumulated: bytes, deadline: deadline)
            }
        }
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 65_536, completion: completion)
    }

}

private extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
