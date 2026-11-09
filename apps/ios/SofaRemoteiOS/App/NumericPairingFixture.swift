#if DEBUG && targetEnvironment(simulator)
    import AppleCore
    import Foundation
    import UIKit

    /// Uses production SRP, wire validation and Mac enrollment logic, with no
    /// network, Keychain, desktop control or real-device side effects.
    @MainActor
    final class NumericPairingFixtureServer {
        let identity: NumericPairingMacIdentity
        private let state: RemoteState
        private var coordinator: NumericPairingCoordinator!
        private var peers: [UUID: WeakPeer] = [:]
        private var tokens: [String] = []
        private var now = 0.0
        private var expiryTask: Task<Void, Never>?

        private final class WeakPeer {
            weak var value: NumericPairingFixturePeer?
            init(_ value: NumericPairingFixturePeer) { self.value = value }
        }

        init(state: RemoteState, code: String?, expires: Bool) {
            self.state = state
            identity = NumericPairingMacIdentity(
                serviceName: "00000000-0000-4000-8000-000000000042", name: state.deviceName,
                certificateSHA256: PairingSecurity.fingerprint(
                    Data("numeric UI fixture certificate".utf8)))
            coordinator = NumericPairingCoordinator(
                identity: identity, isUnlocked: { true },
                canPair: { [weak self] in (self?.tokens.count ?? 8) < 8 },
                now: { [weak self] in self?.now ?? 0 },
                makeCode: { previous in
                    if let code, NumericPairingCode.isValid(code), code != previous { return code }
                    return NumericPairingCode.generate(excluding: previous)
                })
            coordinator.onSend = { [weak self] id, packet in
                guard let self else { return }
                self.peers[id]?.value?.deliver(WireMessage(type: .pairing, pairing: packet))
                if expires, packet.phase == .ready {
                    self.expiryTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let self, !Task.isCancelled else { return }
                        self.now = 120
                        self.coordinator.tick()
                    }
                }
            }
            coordinator.onClose = { [weak self] id in self?.peers[id]?.value?.close() }
            coordinator.onAuthorize = { [weak self] id, _ in
                guard let self, let token = try? PairingSecurity.randomToken() else { return }
                self.tokens.append(token)
                self.peers[id]?.value?.deliver(
                    WireMessage(
                        type: .welcome, authToken: token,
                        connectionID: UUID().uuidString, state: self.state))
            }
        }

        func makePeer() -> NumericPairingFixturePeer {
            let peer = NumericPairingFixturePeer(server: self)
            peers[peer.id] = WeakPeer(peer)
            return peer
        }

        func receive(_ message: WireMessage, from id: UUID) {
            if message.type == .pairing, let packet = message.pairing {
                coordinator.receive(packet, from: id)
            } else if message.type == .authenticate, let token = message.authToken,
                tokens.contains(where: { PairingSecurity.matches($0, token) })
            {
                peers[id]?.value?.deliver(
                    WireMessage(
                        type: .welcome,
                        connectionID: UUID().uuidString, state: state))
            } else {
                peers[id]?.value?.close()
            }
        }

        func disconnected(_ id: UUID) {
            coordinator.disconnected(id)
            peers.removeValue(forKey: id)
            expiryTask?.cancel()
            expiryTask = nil
        }
    }

    @MainActor
    final class NumericPairingFixturePeer: RemotePeer {
        let id = UUID()
        var onReady: (() -> Void)?
        var onMessage: ((WireMessage) -> Void)?
        var onClose: ((String) -> Void)?
        private let server: NumericPairingFixtureServer
        private var closed = false

        init(server: NumericPairingFixtureServer) { self.server = server }
        func start() { if !closed { onReady?() } }

        func send(_ message: WireMessage) {
            guard !closed else { return }
            do { server.receive(try WireCodec.decode(WireCodec.encode(message)), from: id) } catch {
                close()
            }
        }

        func deliver(_ message: WireMessage) {
            guard !closed else { return }
            do { onMessage?(try WireCodec.decode(WireCodec.encode(message))) } catch { close() }
        }

        func close() {
            guard !closed else { return }
            closed = true
            server.disconnected(id)
            onClose?("Disconnected")
            onReady = nil; onMessage = nil; onClose = nil
        }
    }

    extension RemoteModel {
        func reconnectNumericFixture(to saved: PairedMac, server: NumericPairingFixtureServer) {
            disconnect()
            guard
                PairingSecurity.matches(saved.certificateSHA256, server.identity.certificateSHA256)
            else {
                errorMessage = NumericPairingFailure.invalidHandshake.localizedDescription; return
            }
            candidate = saved
            attemptID = UUID()
            let peer = server.makePeer()
            self.peer = peer
            peer.onReady = { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer else { return }
                peer.send(
                    WireMessage(
                        type: .authenticate, authToken: saved.token,
                        deviceName: DeviceName.bounded(UIDevice.current.name)))
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
            peer.start()
        }
    }
#endif
