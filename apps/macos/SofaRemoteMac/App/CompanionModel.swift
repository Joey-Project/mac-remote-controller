import AppleCore
import Foundation
import MacSupport
import Network
import Observation

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
    let mediaAdapters = MediaAdapterController()
    let unlockController = UnlockController()
    let sessionDisplay = SessionDisplayController()
    var pendingSessionControlID: UUID?
    let phoneRecovery = PhoneRecoveryController()
    @ObservationIgnored var numericPairing: NumericPairingCoordinator?
    @ObservationIgnored let numericPairingWindow = NumericPairingWindowController()

    private var listener: NWListener?
    @ObservationIgnored private var blePeripheral: MacBLEPeripheral?
    private var listenerReady = false
    private(set) var identity: LocalIdentity?
    var clients: [UUID: ClientConnection] = [:]
    var pendingHeldInputReleases: [UUID: HeldInputState] = [:]
    var pendingGestureReleases: [UUID: SimulatedGestureState] = [:]
    var heldPointerOwner: UUID?
    var admission = ConnectionAdmission<UUID>()
    var pairing: PairingInvitation?
    private var timer: Timer?
    var canOpenPairing: Bool { listenerReady && listener != nil }

    init() {
        remoteState = desktop.state
        do {
            pairedDevices =
                try SecureStore.load([PairedDevice].self, account: "paired-devices") ?? []
            let loadedIdentity = try ServerIdentity.loadOrCreate()
            identity = loadedIdentity
            configureNumericPairing(identity: loadedIdentity)
            mediaAdapters.onTargetsChanged = { [weak self] targets in
                self?.remoteState.mediaTargets = targets
            }
            mediaAdapters.restoreEnabled()
            unlockController.pairedDeviceIDs = { [weak self] in
                Set(self?.pairedDevices.map(\.id) ?? [])
            }
            unlockController.onChange = { [weak self] in self?.refreshStateAndBroadcast() }
            unlockController.refreshIfDue()
            try startListener()
            let pairedTokens: () -> [(id: String, token: String)] = { [weak self] in
                self?.pairedDevices.map { (id: $0.id, token: $0.token) } ?? []
            }
            let blePeripheral = MacBLEPeripheral(
                serviceName: loadedIdentity.serviceName, pairedTokens: pairedTokens)
            self.blePeripheral = blePeripheral
            blePeripheral.onAuthenticated = { [weak self] peer, deviceID, deviceName in
                self?.acceptAuthenticated(peer, deviceID: deviceID, deviceName: deviceName)
            }
            blePeripheral.onStatus = { [weak self] status in self?.bleStatus = status }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } catch {
            summary = "Companion unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func prepareForTermination() -> Bool {
        guard cancelGesturesForTermination() else { return false }
        var active = clients.mapValues { $0.inputState.heldInput }
        let released = HeldInputTermination.prepare(
            active: &active, pending: &pendingHeldInputReleases,
            release: { desktop.release(&$0) })
        for (id, held) in active { clients[id]?.inputState.heldInput = held }
        guard released else {
            errorMessage =
                "The pointer could not be released. Restore Accessibility access and quit again."
            return false
        }
        numericPairing?.cancel()
        heldPointerOwner = nil
        sessionDisplay.endRemoteControl()
        timer?.invalidate()
        timer = nil
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) { removeClient(id, closePeer: true) }
        return true
    }

    func setMediaBridgeEnabled(_ enabled: Bool) {
        mediaAdapters.setEnabled(enabled)
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
                state: stateForClient(remoteState, client: client)))
        refreshConnectedCount()
    }
}

extension CompanionModel {
    private func receive(_ message: WireMessage, from id: UUID) {
        guard let client = clients[id] else { return }
        guard allowIncomingMessage(from: client) else { return }
        guard let session = client.session else {
            if message.type == .pairing, let packet = message.pairing,
                client.peer is WebSocketPeer, let numericPairing
            {
                numericPairing.receive(packet, from: id)
            } else if numericPairing?.ownsConnection(id) == true {
                client.peer.close()
            } else {
                authenticate(message, client: client, id: id)
            }
            return
        }

        switch message.type {
        case .ping:
            receiveProbe(message, client: client, session: session)
        case .disconnect:
            client.peer.close()
        case .command:
            receiveCommand(message, client: client, session: session, id: id)
        default:
            client.peer.close()
        }
    }

    private func allowIncomingMessage(from client: ClientConnection) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now - client.rateWindowUptime >= 1 {
            client.rateWindowUptime = now
            client.receivedCount = 0
        }
        client.receivedCount += 1
        guard client.receivedCount <= 240 else { client.peer.close(); return false }
        return true
    }

    private func receiveCommand(
        _ message: WireMessage,
        client: ClientConnection,
        session originalSession: ServerSession,
        id: UUID
    ) {
        var session = originalSession
        do {
            let accepted = try session.accept(message)
            client.session = session
            if accepted.command.name == .mediaControl, let request = accepted.command.mediaRequest {
                startMediaCommand(
                    accepted, request: request, session: session, client: client, id: id)
                return
            }
            if accepted.command.name == .sessionUnlock {
                startUnlockCommand(accepted, session: session, client: client, id: id)
                return
            }
            if SessionControlPolicy.isControl(accepted.command.name) {
                startSessionControl(accepted, session: session, client: client, id: id)
                return
            }
            let failure = execute(accepted.command, for: client, id: id)
            client.peer.send(session.makeResult(for: accepted, error: failure))
            if accepted.command.name == .systemVolumeSet { refreshStateAndBroadcast() }
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

    private func tick() {
        mediaAdapters.expireStaleTargets()
        unlockController.refreshIfDue()
        refreshStateAndBroadcast()
        if let pairing, pairing.expiresAt <= Date() { closePairing() }
        let now = ProcessInfo.processInfo.systemUptime
        let expired = clients.filter { id, client in
            client.session == nil && numericPairing?.ownsConnection(id) != true
                && now - client.connectedAtUptime > 10
        }.map { $0.value }
        for client in expired { client.peer.close() }
        numericPairing?.tick()
        releaseExpiredInput(at: now)
        retryPendingHeldInputReleases()
    }

    func refreshConnectedCount() {
        connectedCount = admission.authenticatedCount
    }

    func removeClient(_ id: UUID, closePeer: Bool = false) {
        guard let client = clients.removeValue(forKey: id) else { return }
        numericPairing?.disconnected(id)
        if let session = client.session {
            mediaAdapters.router.cancel(sessionID: session.connectionID)
        }
        for task in client.pendingMediaTasks.values { task.cancel() }
        client.pendingUnlockTask?.cancel()
        client.pendingSessionControlTask?.cancel()
        unlockController.cancel(connection: id)
        client.pendingMediaTasks.removeAll()
        desktop.cancelGesture(&client.inputState.gesture)
        if client.inputState.gesture.isActive {
            pendingGestureReleases[id] = client.inputState.gesture
        }
        desktop.release(&client.inputState.heldInput)
        if !client.inputState.hasHeldInput {
            if heldPointerOwner == id { heldPointerOwner = nil }
        } else if !client.inputState.heldInput.buttons.isEmpty {
            pendingHeldInputReleases[id] = client.inputState.heldInput
            heldPointerOwner = id
        }
        _ = admission.remove(id)
        refreshConnectedCount()
        if connectedCount == 0 { sessionDisplay.endRemoteControl() }
        if closePeer { client.peer.close() }
    }

}
