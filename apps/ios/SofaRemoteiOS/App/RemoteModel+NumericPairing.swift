import AppleCore
import Foundation
import Network
import Observation
import UIKit

@MainActor
@Observable
final class NumericPairingClientState: Identifiable {
    enum Phase: Equatable {
        case connecting, input, starting, challenge, proving, accepted, verifying, welcome,
            resetting
    }
    let id = UUID()
    let mac: DiscoveredMac
    let deviceName = DeviceName.bounded(UIDevice.current.name)
    let crypto: NumericPairingClientCrypto
    var phase: Phase = .connecting
    var macName: String
    var certificateSHA256: String?
    var expiresAt: ContinuousClock.Instant?
    var remainingAttempts = 3
    var errorMessage: String?
    var attemptID: UUID?
    @ObservationIgnored var task: Task<Void, Never>?

    init(mac: DiscoveredMac) {
        self.mac = mac
        macName = mac.name
        crypto = NumericPairingClientCrypto(requestID: id)
    }
}

extension RemoteModel {
    func requestNumericPairing(to mac: DiscoveredMac) {
        guard selectedTransport == .wifi, !mac.isPaired else { return }
        disconnect()
        candidate = nil
        errorMessage = nil
        connectionSummary = "Requesting a code on the Mac…"
        let state = NumericPairingClientState(mac: mac)
        numericPairing = state
        let attempt = UUID()
        attemptID = attempt
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                guard let server = uiTestFixture.numericServer else {
                    failNumericPairing(.unavailable)
                    return
                }
                state.certificateSHA256 = server.identity.certificateSHA256
                let peer = server.makePeer()
                installNumericPeer(peer, state: state)
                peer.start()
                return
            }
        #endif
        let resolver = BonjourResolver()
        self.resolver = resolver
        resolver.resolve(
            serviceName: mac.id, wakeOnResolve: true, interfaceIndex: mac.interfaceIndex ?? 0
        ) { [weak self, weak state] result in
            guard let self, let state, self.numericPairing === state, self.attemptID == attempt
            else { return }
            self.resolver = nil
            switch result {
            case .success(let url): self.startNumericConnection(url: url, state: state)
            case .failure: self.failNumericPairing(.unavailable)
            }
        }
    }

    private func startNumericConnection(url: URL, state: NumericPairingClientState) {
        let parameters = WebSocketPeer.parameters(
            onTrustFailure: { [weak self, weak state] in
                guard let self, let state, self.numericPairing === state else { return }
                self.failNumericPairing(.invalidHandshake)
            },
            onPairingCertificate: { [weak self, weak state] fingerprint in
                guard let self, let state, self.numericPairing === state else { return }
                if let old = state.certificateSHA256, !PairingSecurity.matches(old, fingerprint) {
                    self.failNumericPairing(.invalidHandshake)
                } else {
                    state.certificateSHA256 = fingerprint
                }
            })
        let peer = WebSocketPeer(connection: NWConnection(to: .url(url), using: parameters))
        installNumericPeer(peer, state: state)
        peer.start()
    }

    private func installNumericPeer(_ peer: RemotePeer, state: NumericPairingClientState) {
        self.peer = peer
        peer.onReady = { [weak self, weak state] in
            guard let self, let state, self.numericPairing === state, state.certificateSHA256 != nil
            else { return }
            var packet = NumericPairingMessage(id: state.id, phase: .request)
            packet.serviceName = state.mac.id
            packet.name = state.deviceName
            self.peer?.send(WireMessage(type: .pairing, pairing: packet))
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.receive(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.handleClose(reason)
        }
        monitorConnection()
    }

    func submitNumericCode(_ code: String) {
        guard let state = numericPairing, state.phase == .input, NumericPairingCode.isValid(code)
        else { return }
        state.phase = .starting
        state.errorMessage = nil
        state.task = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            do {
                let key = try await state.crypto.begin(code: code)
                guard !Task.isCancelled, self.numericPairing === state else { return }
                state.phase = .challenge
                state.task = nil
                var hello = NumericPairingMessage(id: state.id, phase: .hello)
                hello.publicKey = key
                self.peer?.send(WireMessage(type: .pairing, pairing: hello))
            } catch {
                guard !Task.isCancelled, self.numericPairing === state else { return }
                self.failNumericPairing(.invalidHandshake)
            }
        }
    }

    func receiveNumericPairing(_ packet: NumericPairingMessage) {
        guard let state = numericPairing, packet.id == state.id else { peer?.close(); return }
        switch packet.phase {
        case .ready where state.phase == .connecting:
            acceptNumericReady(packet, state: state)
        case .challenge where state.phase == .challenge:
            answerNumericChallenge(packet, state: state)
        case .accepted where state.phase == .accepted && packet.attemptID == state.attemptID:
            acceptNumericServer(packet, state: state)
        case .retry where state.phase == .accepted:
            guard let remaining = packet.remainingAttempts, remaining == state.remainingAttempts - 1
            else {
                failNumericPairing(.invalidHandshake); return
            }
            state.phase = .resetting
            state.remainingAttempts = remaining
            state.attemptID = nil
            state.task = Task { @MainActor [weak self, weak state] in
                guard let self, let state else { return }
                await state.crypto.cancel()
                guard !Task.isCancelled, self.numericPairing === state else { return }
                state.task = nil
                state.errorMessage = NumericPairingFailure.incorrectCode.localizedDescription
                state.phase = .input
            }
        case .rejected:
            failNumericPairing(packet.failure ?? .invalidHandshake)
        default: failNumericPairing(.invalidHandshake)
        }
    }

    private func acceptNumericReady(
        _ packet: NumericPairingMessage, state: NumericPairingClientState
    ) {
        guard packet.serviceName == state.mac.id, let name = packet.name,
            let ttl = packet.expiresIn, packet.remainingAttempts == 3
        else {
            failNumericPairing(.invalidHandshake); return
        }
        state.macName = name
        state.expiresAt = .now + .seconds(ttl)
        state.phase = .input
        connectionSummary = "Enter the code shown on \(name)"
    }

    private func answerNumericChallenge(
        _ packet: NumericPairingMessage, state: NumericPairingClientState
    ) {
        guard let attempt = packet.attemptID, let salt = packet.salt,
            let publicKey = packet.publicKey, let fingerprint = state.certificateSHA256
        else {
            failNumericPairing(.invalidHandshake); return
        }
        state.attemptID = attempt
        state.phase = .proving
        let context = NumericPairingContext(
            requestID: state.id, attemptID: attempt, serviceName: state.mac.id,
            certificateSHA256: fingerprint, deviceName: state.deviceName, macName: state.macName)
        state.task = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            do {
                let response = try await state.crypto.answer(
                    NumericPairingChallenge(salt: salt, publicKey: publicKey), context: context)
                guard !Task.isCancelled, self.numericPairing === state else { return }
                state.phase = .accepted
                state.task = nil
                var proof = NumericPairingMessage(id: state.id, phase: .proof)
                proof.attemptID = attempt
                proof.proof = response.proof
                proof.binding = response.binding
                self.peer?.send(WireMessage(type: .pairing, pairing: proof))
            } catch {
                guard !Task.isCancelled, self.numericPairing === state else { return }
                self.failNumericPairing(.invalidHandshake)
            }
        }
    }

    private func acceptNumericServer(
        _ packet: NumericPairingMessage, state: NumericPairingClientState
    ) {
        guard let proof = packet.proof, let binding = packet.binding,
            let fingerprint = state.certificateSHA256
        else {
            failNumericPairing(.invalidHandshake); return
        }
        state.phase = .verifying
        state.task = Task { @MainActor [weak self, weak state] in
            guard let self, let state else { return }
            do {
                let finish = try await state.crypto.accept(
                    NumericPairingProof(proof: proof, binding: binding))
                guard !Task.isCancelled, self.numericPairing === state else { return }
                self.candidate = PairedMac(
                    serviceName: state.mac.id, name: state.macName, certificateSHA256: fingerprint,
                    token: "")
                state.phase = .welcome
                state.task = nil
                var packet = NumericPairingMessage(id: state.id, phase: .finish)
                packet.attemptID = state.attemptID
                packet.binding = finish
                self.peer?.send(WireMessage(type: .pairing, pairing: packet))
            } catch {
                guard !Task.isCancelled, self.numericPairing === state else { return }
                self.failNumericPairing(.invalidHandshake)
            }
        }
    }

    func failNumericPairing(_ failure: NumericPairingFailure) {
        disconnect()
        errorMessage = failure.localizedDescription
    }

    func clearNumericPairing() {
        let state = numericPairing
        numericPairing = nil
        state?.task?.cancel()
        if let crypto = state?.crypto { Task { await crypto.cancel() } }
    }
}
