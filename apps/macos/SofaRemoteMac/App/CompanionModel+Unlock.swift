import AppleCore
import Foundation
import MacSupport

extension CompanionModel {
    func revoke(_ device: PairedDevice) {
        do {
            let updated = pairedDevices.filter { $0.id != device.id }
            try SecureStore.save(updated, account: "paired-devices")
            pairedDevices = updated
            unlockController.setDevice(device.id, allowed: false)
            let affected = clients.values.filter { $0.deviceID == device.id }
            for client in affected { client.peer.close() }
        } catch { errorMessage = error.localizedDescription }
    }

    func startUnlockCommand(
        _ accepted: AcceptedCommand, session: ServerSession, client: ClientConnection, id: UUID
    ) {
        guard client.pendingUnlockTask == nil, let device = client.deviceID else {
            client.peer.send(
                session.makeResult(
                    for: accepted,
                    error: RemoteError(
                        code: "unlock_busy", message: "An unlock request is already in progress.")))
            return
        }
        client.pendingUnlockTask = Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            defer { client.pendingUnlockTask = nil }
            var failure: RemoteError?
            do {
                try await self.unlockController.unlock(device: device, connection: id)
            } catch {
                failure = RemoteError(
                    code: "unlock_unconfirmed",
                    message: (error as? LocalizedError)?.errorDescription
                        ?? "Unlock was not confirmed. The request was not retried.")
            }
            guard self.clients[id] === client, !Task.isCancelled else { return }
            client.peer.send(session.makeResult(for: accepted, error: failure))
        }
    }
}
