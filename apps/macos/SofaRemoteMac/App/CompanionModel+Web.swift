import AppleCore
import Foundation
import WebRemoteSupport

extension CompanionModel {
    func configureWebRemote() {
        webRemote.isUnlocked = { [weak self] in self?.sessionDisplay.sessionLocked == false }
        webRemote.canPair = { [weak self] in (self?.pairedDevices.count ?? 8) < 8 }
        webRemote.deviceName = { [weak self] in self?.remoteState.deviceName ?? "Mac" }
        webRemote.authorize = { [weak self] name in
            guard let self, self.pairedDevices.count < 8, self.sessionDisplay.sessionLocked == false
            else {
                throw WebPairingFailure.unavailable
            }
            let device = PairedDevice(
                id: UUID().uuidString, name: DeviceName.bounded("Browser · \(name)"),
                token: try PairingSecurity.randomToken())
            let updated = self.pairedDevices + [device]
            try SecureStore.save(updated, account: "paired-devices")
            self.pairedDevices = updated
            return device.token
        }
        webRemote.resolveCredential = { [weak self] token in
            self?.pairedDevices.first { PairingSecurity.matches($0.token, token) }?.name
        }
        webRemote.forgetCredential = { [weak self] token in
            guard let self,
                let device = self.pairedDevices.first(where: {
                    PairingSecurity.matches($0.token, token)
                })
            else { return }
            self.revoke(device)
            if self.pairedDevices.contains(where: { $0.id == device.id }) {
                throw WebConfigurationError.unavailable
            }
        }
        webRemote.onPeer = { [weak self] peer in self?.acceptWebRemote(peer) }
        webRemote.reload()
    }
}
