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
    let peer: RemotePeer
    var session: ServerSession?
    var scrollAccumulator = PixelScrollAccumulator()
    var deviceID: String?
    let connectedAt = Date()
    var rateWindow = Date()
    var receivedCount = 0

    init(peer: RemotePeer) { self.peer = peer }
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
    var bleStatus = "Starting Bluetooth…"
    var probeCount = 0
    var lastProbeProcessingMilliseconds: Double?
    let desktop = DesktopController()

    private var listener: NWListener?
    @ObservationIgnored private var blePeripheral: MacBLEPeripheral?
    private var listenerReady = false
    private var identity: LocalIdentity?
    private var clients: [UUID: ClientConnection] = [:]
    private var admission = ConnectionAdmission<UUID>()
    private var pairing: PairingInvitation?
    private var timer: Timer?

    init() {
        remoteState = desktop.state
        do {
            pairedDevices =
                try SecureStore.load([PairedDevice].self, account: "paired-devices") ?? []
            let identity = try ServerIdentity.loadOrCreate()
            self.identity = identity
            try startListener()
            let blePeripheral = MacBLEPeripheral(serviceName: identity.serviceName) { [weak self] in
                self?.pairedDevices.map { (id: $0.id, token: $0.token) } ?? []
            }
            self.blePeripheral = blePeripheral
            blePeripheral.onAuthenticated = { [weak self] peer, deviceID, deviceName in
                self?.acceptAuthenticated(peer, deviceID: deviceID, deviceName: deviceName)
            }
            blePeripheral.onStatus = { [weak self] status in self?.bleStatus = status }
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
        let peer = WebSocketPeer(connection: connection)
        accept(peer)
    }

    private func accept(_ peer: RemotePeer) {
        let id = UUID()
        if let evictedID = admission.admitPending(id) {
            removeClient(evictedID, closePeer: true)
        }
        clients[id] = ClientConnection(peer: peer)
        peer.onMessage = { [weak self] message in self?.receive(message, from: id) }
        peer.onClose = { [weak self] _ in self?.removeClient(id) }
        (peer as? WebSocketPeer)?.start()
    }

    private func acceptAuthenticated(
        _ peer: MacBLEPeripheral, deviceID: String, deviceName: String
    ) {
        guard pairedDevices.contains(where: { $0.id == deviceID }) else { peer.close(); return }
        let id = UUID()
        if let evictedID = admission.admitPending(id) { removeClient(evictedID, closePeer: true) }
        let previousIDs = clients.compactMap { otherID, other in
            other.deviceID == deviceID ? otherID : nil
        }
        for previousID in previousIDs { removeClient(previousID, closePeer: true) }
        guard admission.authenticate(id) else { peer.close(); return }
        let session = ServerSession(connectionID: UUID().uuidString)
        peer.setConnectionID(session.connectionID)
        let client = ClientConnection(peer: peer)
        client.deviceID = deviceID
        client.session = session
        clients[id] = client
        peer.onMessage = { [weak self] message in self?.receive(message, from: id) }
        peer.onClose = { [weak self] _ in self?.removeClient(id) }
        peer.send(
            WireMessage(
                type: .welcome, connectionID: session.connectionID,
                state: stateForClient(deviceName: desktop.state.deviceName)))
        refreshConnectedCount()
    }
}

extension CompanionModel {
    private func receive(_ message: WireMessage, from id: UUID) {
        guard let client = clients[id] else { return }
        guard allowIncomingMessage(from: client) else { return }
        guard let session = client.session else {
            authenticate(message, client: client, id: id)
            return
        }

        switch message.type {
        case .ping:
            receiveProbe(message, client: client, session: session)
        case .disconnect:
            client.peer.close()
        case .command:
            receiveCommand(message, client: client, session: session)
        default:
            client.peer.close()
        }
    }

    private func allowIncomingMessage(from client: ClientConnection) -> Bool {
        if Date().timeIntervalSince(client.rateWindow) >= 1 {
            client.rateWindow = Date()
            client.receivedCount = 0
        }
        client.receivedCount += 1
        guard client.receivedCount <= 240 else { client.peer.close(); return false }
        return true
    }

    private func receiveProbe(
        _ message: WireMessage, client: ClientConnection, session: ServerSession
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard message.connectionID == session.connectionID,
            let requestID = message.requestID, let sequence = message.sequence
        else { client.peer.close(); return }
        let pong = WireMessage(
            type: .pong, connectionID: session.connectionID,
            requestID: requestID, sequence: sequence)
        client.peer.send(pong)
        lastProbeProcessingMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        probeCount += 1
    }

    private func receiveCommand(
        _ message: WireMessage, client: ClientConnection, session originalSession: ServerSession
    ) {
        var session = originalSession
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

    private func authenticate(_ message: WireMessage, client: ClientConnection, id: UUID) {
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
            let previousIDs = clients.compactMap { id, other in
                other !== client && other.deviceID == device.id ? id : nil
            }
            for previousID in previousIDs { removeClient(previousID, closePeer: true) }
            guard admission.authenticate(id) else {
                client.peer.close()
                return
            }
            client.deviceID = device.id
            let session = ServerSession(connectionID: UUID().uuidString)
            client.session = session
            client.peer.send(
                WireMessage(
                    type: .welcome, authToken: issuedToken,
                    connectionID: session.connectionID,
                    state: stateForClient(deviceName: desktop.state.deviceName)))
            refreshConnectedCount()
        } catch {
            errorMessage = error.localizedDescription
            client.peer.close()
        }
    }

    private func sendState(to client: ClientConnection) {
        guard let session = client.session else { return }
        client.peer.send(
            WireMessage(
                type: .state, connectionID: session.connectionID,
                state: stateForClient(deviceName: desktop.state.deviceName)))
    }

    private func stateForClient(deviceName: String) -> RemoteState {
        var state = desktop.state
        state.deviceName = deviceName
        state.capabilities = [WireCapabilities.roundTripProbe]
        return state
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
        connectedCount = admission.authenticatedCount
    }

    private func removeClient(_ id: UUID, closePeer: Bool = false) {
        guard let client = clients.removeValue(forKey: id) else { return }
        _ = admission.remove(id)
        refreshConnectedCount()
        if closePeer { client.peer.close() }
    }
}
