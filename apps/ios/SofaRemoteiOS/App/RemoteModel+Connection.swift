import AppleCore
import Foundation
import Network
import UIKit

extension RemoteModel {
    func connectSaved(to mac: DiscoveredMac) {
        if !mac.isPaired { requestNumericPairing(to: mac); return }
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                if let server = uiTestFixture.numericServer,
                    let saved = pairedMacs.first(where: { $0.serviceName == mac.id })
                {
                    reconnectNumericFixture(to: saved, server: server)
                }
                return
            }
        #endif
        guard let saved = pairedMacs.first(where: { $0.serviceName == mac.id }) else {
            errorMessage = "Open pairing on this Mac and scan its invitation."
            return
        }
        benchmarkTargetID = saved.serviceName
        connect(saved, interfaceIndex: mac.interfaceIndex ?? 0)
    }

    func pair(invitation: String) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        guard selectedTransport == .wifi else {
            errorMessage = "Pair this Mac over Wi-Fi first, then select Bluetooth LE to reconnect."
            return
        }
        do {
            let invitation = try PairingInvitation.parse(
                invitation.trimmingCharacters(in: .whitespacesAndNewlines))
            connect(
                PairedMac(
                    serviceName: invitation.serviceName, name: "Mac",
                    certificateSHA256: invitation.certificateSHA256, token: invitation.token))
        } catch { errorMessage = error.localizedDescription }
    }

    func connect(_ mac: PairedMac, interfaceIndex: UInt32 = 0) {
        #if DEBUG && targetEnvironment(simulator)
            guard !isUITesting else { return }
        #endif
        disconnect()
        errorMessage = nil
        connectionSummary = "Resolving Mac…"
        candidate = mac
        benchmarkTargetID = mac.serviceName
        let attempt = UUID()
        attemptID = attempt
        if selectedTransport == .bluetooth {
            startBluetoothConnection(to: mac, attempt: attempt)
            return
        }
        let resolver = BonjourResolver()
        self.resolver = resolver
        resolver.resolve(
            serviceName: mac.serviceName, wakeOnResolve: true, interfaceIndex: interfaceIndex
        ) { [weak self] result in
            guard let self, self.attemptID == attempt else { return }
            self.resolver = nil
            switch result {
            case .success(let url): self.startConnection(to: url, mac: mac, attempt: attempt)
            case .failure: self.handleClose("The Mac could not be found on this network.")
            }
        }
    }

    private func startConnection(to url: URL, mac: PairedMac, attempt: UUID) {
        connectionSummary = "Connecting securely…"
        let parameters = WebSocketPeer.parameters(pin: mac.certificateSHA256) { [weak self] in
            guard let self, self.attemptID == attempt else { return }
            self.peer?.close()
            self.errorMessage =
                "The Mac identity does not match. Open pairing on the Mac and scan a new invitation."
        }
        let peer = WebSocketPeer(
            connection: NWConnection(to: .url(url), using: parameters))
        self.peer = peer
        peer.onReady = { [weak self] in
            let name = DeviceName.bounded(UIDevice.current.name)
            self?.peer?.send(
                WireMessage(type: .authenticate, authToken: mac.token, deviceName: name))
        }
        peer.onMessage = { [weak self] message in self?.receive(message) }
        peer.onClose = { [weak self] reason in self?.handleClose(reason) }
        monitorConnection()
        peer.start()
    }

}
