import AppleCore
import Foundation
import MacSupport
import Network
import Observation

struct PairedDevice: Codable, Identifiable {
    let id: String
    let name: String
    let token: String
}

@MainActor
private final class ClientConnection {
    let peer: WebSocketPeer
    var session: ServerSession?
    var scrollAccumulator = PixelScrollAccumulator()
    var deviceID: String?
    let connectedAt = Date()
    var rateWindow = Date()
    var receivedCount = 0

    init(peer: WebSocketPeer) { self.peer = peer }
}

@MainActor
@Observable
final class CompanionModel {
    var summary = "Starting secure companion…"
    var errorMessage: String?
    var invitation: String?
    var invitationExpiresAt: Date?
    var pairedDevices: [PairedDevice] = []
    var remoteState: RemoteState
    var connectedCount = 0
    let desktop = DesktopController()

    private var listener: NWListener?
    private var listenerReady = false
    private var identity: LocalIdentity?
    private var clients: [UUID: ClientConnection] = [:]
    private var pairing: PairingInvitation?
    private var timer: Timer?

    init() {
        remoteState = desktop.state
        do {
            pairedDevices =
                try SecureStore.load([PairedDevice].self, account: "paired-devices") ?? []
            identity = try ServerIdentity.loadOrCreate()
            try startListener()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            summary = "Companion unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func openPairing() {
        guard listenerReady, listener != nil, let identity else { return }
        do {
            guard pairedDevices.count < 8 else {
                errorMessage = "Remove a paired device before adding another (maximum 8)."
                return
            }
            let invitation = PairingInvitation(
                serviceName: identity.serviceName,
                certificateSHA256: PairingSecurity.fingerprint(identity.certificateDER),
                token: try PairingSecurity.randomToken(), expiresAt: Date().addingTimeInterval(120))
            self.invitation = try invitation.url()
            invitationExpiresAt = invitation.expiresAt
            pairing = invitation
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func closePairing() {
        pairing = nil
        invitation = nil
        invitationExpiresAt = nil
    }

    func revoke(_ device: PairedDevice) {
        do {
            let updated = pairedDevices.filter { $0.id != device.id }
            try SecureStore.save(updated, account: "paired-devices")
            pairedDevices = updated
            let affected = clients.values.filter { $0.deviceID == device.id }
            for client in affected { client.peer.close() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func startListener() throws {
        guard let identity else { return }
        let listener = try NWListener(using: WebSocketPeer.parameters(identity: identity.identity))
        listener.service = NWListener.Service(name: identity.serviceName, type: "_sofaremote._tcp")
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.listenerReady = true
                    self.summary = "Ready on the local network"
                case .failed:
                    self.listenerReady = false
                    listener.cancel()
                    self.listener = nil
                    self.summary = "Network unavailable"
                    self.errorMessage =
                        "Check Local Network permission and your Wi-Fi connection. Restart Sofa Remote to retry."
                    self.closePairing()
                case .waiting, .cancelled:
                    self.listenerReady = false
                    self.summary = "Local network listener unavailable"
                    self.closePairing()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 12 else { connection.cancel(); return }
        let id = UUID()
        let peer = WebSocketPeer(connection: connection)
        clients[id] = ClientConnection(peer: peer)
        peer.onMessage = { [weak self] message in self?.receive(message, from: id) }
        peer.onClose = { [weak self] _ in
            self?.clients.removeValue(forKey: id)
            self?.refreshConnectedCount()
        }
        peer.start()
    }

    private func receive(_ message: WireMessage, from id: UUID) {
        guard let client = clients[id] else { return }
        if Date().timeIntervalSince(client.rateWindow) >= 1 {
            client.rateWindow = Date()
            client.receivedCount = 0
        }
        client.receivedCount += 1
        guard client.receivedCount <= 240 else { client.peer.close(); return }
        guard var session = client.session else {
            authenticate(message, client: client)
            return
        }
        guard message.type == .command else { client.peer.close(); return }
        do {
            let accepted = try session.accept(message)
            client.session = session
            var failure: RemoteError?
            do { try desktop.execute(accepted.command, scroll: &client.scrollAccumulator) } catch {
                failure = RemoteError(
                    code: "control_unavailable", message: error.localizedDescription)
            }
            client.peer.send(session.makeResult(for: accepted, error: failure))
            sendState(to: client)
        } catch {
            client.session = session
            guard message.connectionID == session.connectionID, let requestID = message.requestID,
                let sequence = message.sequence
            else { client.peer.close(); return }
            client.peer.send(
                WireMessage(
                    type: .result, connectionID: session.connectionID,
                    requestID: requestID, sequence: sequence,
                    error: RemoteError(
                        code: "invalid_command",
                        message: "This control request is invalid or out of order.")))
        }
    }

    private func authenticate(_ message: WireMessage, client: ClientConnection) {
        guard message.type == .authenticate, let token = message.authToken,
            let name = message.deviceName
        else {
            client.peer.close()
            return
        }
        do {
            let device: PairedDevice
            var issuedToken: String?
            let knownDevice = pairedDevices.first { PairingSecurity.matches($0.token, token) }
            if let paired = knownDevice {
                device = paired
            } else if let pairing, pairing.expiresAt > Date(),
                PairingSecurity.matches(pairing.token, token), pairedDevices.count < 8
            {
                device = PairedDevice(
                    id: UUID().uuidString, name: name, token: try PairingSecurity.randomToken())
                let updated = pairedDevices + [device]
                try SecureStore.save(updated, account: "paired-devices")
                pairedDevices = updated
                issuedToken = device.token
                closePairing()
            } else {
                client.peer.close()
                return
            }
            let previous = clients.values.filter { $0 !== client && $0.deviceID == device.id }
            for old in previous { old.peer.close() }
            client.deviceID = device.id
            let session = ServerSession(connectionID: UUID().uuidString)
            client.session = session
            client.peer.send(
                WireMessage(
                    type: .welcome, authToken: issuedToken,
                    connectionID: session.connectionID, state: desktop.state))
            refreshConnectedCount()
        } catch {
            errorMessage = error.localizedDescription
            client.peer.close()
        }
    }

    private func sendState(to client: ClientConnection) {
        guard let session = client.session else { return }
        client.peer.send(
            WireMessage(type: .state, connectionID: session.connectionID, state: desktop.state))
    }

    private func tick() {
        remoteState = desktop.state
        if let pairing, pairing.expiresAt <= Date() { closePairing() }
        let expired = clients.values.filter {
            $0.session == nil && Date().timeIntervalSince($0.connectedAt) > 10
        }
        for client in expired { client.peer.close() }
        for client in clients.values where client.session != nil { sendState(to: client) }
    }

    private func refreshConnectedCount() {
        connectedCount = clients.values.filter { $0.session != nil }.count
    }
}
