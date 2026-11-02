import Foundation
import UnlockNative

public final class UnlockBroker: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener = NSXPCListener(machServiceName: UnlockPaths.service)
    private let queue = DispatchQueue(label: "com.joeyteng.sofaremote.unlock.broker")
    private let record: UnlockInstallationRecord
    private var peers: [UUID: UnlockBrokerPeer] = [:]
    private lazy var transactions = UnlockTransactions(queue: queue)

    public init(installation: UnlockInstallationRecord) throws {
        guard geteuid() == 0 else { throw UnlockFailure.unavailable }
        record = installation
        guard record.phase == "installed" else { throw UnlockFailure.setupIncomplete }
        try UnlockSigning.verify(UnlockPaths.helper, requirement: record.helperRequirement)
        try UnlockFiles.withStateLock { try UnlockPolicyControl.clearAuthority() }
        super.init()
        listener.setConnectionCodeSigningRequirement(record.clientRequirement)
        listener.delegate = self
    }

    public func start() { listener.activate() }

    public func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier == record.clientUID else { return false }
        let peer = UnlockBrokerPeer(connection: connection, broker: self)
        connection.exportedInterface = NSXPCInterface(with: UnlockServiceProtocol.self)
        connection.exportedObject = peer
        connection.invalidationHandler = { [weak self, weak peer] in
            guard let peer else { return }
            self?.queue.async { [weak self] in
                self?.transactions.cancel(peer: peer.identifier)
                self?.peers.removeValue(forKey: peer.identifier)
                peer.connection.exportedObject = nil
                peer.connection.invalidationHandler = nil
            }
        }
        queue.async { [weak self] in
            guard let self else { return }
            guard peers.count < 8 else { peer.connection.invalidate(); return }
            peers[peer.identifier] = peer
            peer.connection.activate()
        }
        return true
    }

    fileprivate func perform(
        _ data: Data, peer: UnlockBrokerPeer, reply: @escaping @Sendable (Data) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard data.count <= 4096, peers[peer.identifier] === peer else {
                    throw UnlockFailure.invalidRequest
                }
                let request = try JSONDecoder().decode(UnlockRequest.self, from: data)
                try request.validate()
                try handle(request, peer: peer, reply: reply)
            } catch {
                let failure = (error as? UnlockFailure) ?? .unavailable
                reply(
                    (try? JSONEncoder().encode(UnlockResponse(failure: failure.rawValue))) ?? Data()
                )
            }
        }
    }

    private func handle(
        _ request: UnlockRequest, peer: UnlockBrokerPeer,
        reply: @escaping @Sendable (Data) -> Void
    ) throws {
        switch request.operation {
        case .status: reply(try encodedStatus())
        case .enable:
            try UnlockPolicyControl.enable()
            reply(try encodedStatus())
        case .disable:
            transactions.cancel()
            try UnlockPolicyControl.disable()
            reply(try encodedStatus())
        case .allowDevice, .denyDevice:
            guard let device = request.deviceID else { throw UnlockFailure.invalidRequest }
            transactions.cancel()
            try UnlockPolicyControl.setDevice(
                device, allowed: request.operation == .allowDevice)
            reply(try encodedStatus())
        default: try handleTransaction(request, peer: peer, reply: reply)
        }
    }

    private func handleTransaction(
        _ request: UnlockRequest, peer: UnlockBrokerPeer,
        reply: @escaping @Sendable (Data) -> Void
    ) throws {
        switch request.operation {
        case .begin:
            guard let device = request.deviceID else { throw UnlockFailure.invalidRequest }
            reply(
                try JSONEncoder().encode(
                    transactions.begin(
                        peer: peer.identifier, device: device, clientUID: record.clientUID))
            )
        case .wait:
            guard let identifier = request.transactionID else {
                throw UnlockFailure.invalidRequest
            }
            try transactions.wait(
                peer: peer.identifier, identifier: identifier, reply: reply)
        case .cancel:
            transactions.cancel(peer: peer.identifier, identifier: request.transactionID)
            reply(try encodedStatus())
        default:
            throw UnlockFailure.invalidRequest
        }
    }

    private func encodedStatus() throws -> Data {
        let settings = try UnlockSettings.load()
        let state = SRReadConsole()
        var result = UnlockResponse()
        result.installed = true
        result.enabled = settings.enabled
        result.allowedDeviceIDs = settings.allowedDeviceIDs
        result.locked =
            state.known && state.loggedIn && state.userID == record.clientUID ? state.locked : nil
        return try JSONEncoder().encode(result)
    }
}

private final class UnlockBrokerPeer: NSObject, UnlockServiceProtocol, @unchecked Sendable {
    let identifier = UUID()
    let connection: NSXPCConnection
    weak var broker: UnlockBroker?

    init(connection: NSXPCConnection, broker: UnlockBroker) {
        self.connection = connection
        self.broker = broker
    }

    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let callback = UnlockReply(reply)
        broker?.perform(request, peer: self) { data in callback.send(data) }
    }
}

private final class UnlockReply: @unchecked Sendable {
    private let callback: (Data) -> Void
    init(_ callback: @escaping (Data) -> Void) { self.callback = callback }
    func send(_ data: Data) { callback(data) }
}
