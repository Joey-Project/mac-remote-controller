import AppleCore
import Foundation
import MacSupport
import Network

struct PairedDevice: Codable, Identifiable {
    let id: String
    let name: String
    let token: String
}

@MainActor
final class ClientConnection {
    let peer: RemotePeer
    var session: ServerSession?
    var inputState = DesktopInputState()
    var deviceID: String?
    let connectedAtUptime = ProcessInfo.processInfo.systemUptime
    var rateWindowUptime = ProcessInfo.processInfo.systemUptime
    var receivedCount = 0
    var pendingMediaTasks: [String: Task<Void, Never>] = [:]
    var pendingUnlockTask: Task<Void, Never>?
    var pendingSessionControlTask: Task<Void, Never>?

    init(peer: RemotePeer) { self.peer = peer }
}

extension CompanionModel {
    func openPairing() {
        guard canOpenPairing, let identity else { return }
        numericPairing?.cancel()
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

    func authenticate(_ message: WireMessage, client: ClientConnection, id: UUID) {
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
                    state: stateForClient(remoteState, client: client)))
            refreshConnectedCount()
        } catch {
            errorMessage = error.localizedDescription
            client.peer.close()
        }
    }

    func configureNumericPairing(identity: LocalIdentity) {
        let coordinator = NumericPairingCoordinator(
            identity: NumericPairingMacIdentity(
                serviceName: identity.serviceName, name: remoteState.deviceName,
                certificateSHA256: PairingSecurity.fingerprint(identity.certificateDER)),
            isUnlocked: { [weak self] in self?.sessionDisplay.sessionLocked == false },
            canPair: { [weak self] in (self?.pairedDevices.count ?? 8) < 8 })
        numericPairing = coordinator
        coordinator.onChange = { [weak self] request in
            guard let self else { return }
            self.numericPairingWindow.show(request) { [weak self] in
                self?.numericPairing?.cancel()
            }
        }
        coordinator.onSend = { [weak self] id, packet in
            guard let self, let client = self.clients[id], client.session == nil else { return }
            client.peer.send(WireMessage(type: .pairing, pairing: packet))
            if packet.phase == .rejected {
                Task { @MainActor [weak self, weak client] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let client, self.clients[id] === client,
                        client.session == nil
                    else { return }
                    client.peer.close()
                }
            }
        }
        coordinator.onClose = { [weak self] id in self?.clients[id]?.peer.close() }
        coordinator.onAuthorize = { [weak self] id, name in
            self?.authorizeNumericClient(id, name: name)
        }
    }

    private func authorizeNumericClient(_ id: UUID, name: String) {
        guard let client = clients[id], client.session == nil, pairedDevices.count < 8,
            admission.authenticate(id)
        else { clients[id]?.peer.close(); return }
        do {
            let device = PairedDevice(
                id: UUID().uuidString, name: name, token: try PairingSecurity.randomToken())
            let updated = pairedDevices + [device]
            try SecureStore.save(updated, account: "paired-devices")
            pairedDevices = updated
            client.deviceID = device.id
            let session = ServerSession(connectionID: UUID().uuidString)
            client.session = session
            client.peer.send(
                WireMessage(
                    type: .welcome, authToken: device.token,
                    connectionID: session.connectionID,
                    state: stateForClient(remoteState, client: client)))
            refreshConnectedCount()
        } catch {
            errorMessage = error.localizedDescription
            client.peer.close()
        }
    }
}
