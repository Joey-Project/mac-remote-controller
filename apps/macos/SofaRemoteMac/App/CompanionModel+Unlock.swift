import AppleCore
import Foundation
import MacSupport

extension CompanionModel {
    func refreshStateAndBroadcast() {
        let displayAsleep = sessionDisplay.refresh()
        remoteState = desktop.state
        remoteState.displayAsleep = displayAsleep
        remoteState.mediaTargets = mediaAdapters.mediaTargets
        for client in clients.values where client.session != nil {
            sendState(remoteState, to: client)
        }
    }

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
        guard client.pendingUnlockTask == nil, pendingSessionControlID == nil,
            let device = client.deviceID
        else {
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

    func startSessionControl(
        _ accepted: AcceptedCommand, session: ServerSession, client: ClientConnection, id: UUID
    ) {
        guard pendingSessionControlID == nil, !unlockController.isBusy,
            !clients.values.contains(where: { $0.pendingUnlockTask != nil })
        else {
            client.peer.send(
                session.makeResult(
                    for: accepted,
                    error: RemoteError(
                        code: "session_control_busy",
                        message: SessionDisplayFailure.busy.localizedDescription)))
            return
        }
        let operationID = UUID()
        pendingSessionControlID = operationID
        client.pendingSessionControlTask = Task { @MainActor [weak self, weak client] in
            guard let self else { return }
            defer {
                if self.pendingSessionControlID == operationID {
                    self.pendingSessionControlID = nil
                }
                self.refreshStateAndBroadcast()
            }
            guard let client else { return }
            defer { client.pendingSessionControlTask = nil }
            var failure: RemoteError?
            do {
                try Task.checkCancellation()
                guard self.clients[id] === client, client.deviceID != nil else {
                    throw SessionDisplayFailure.sessionChanged
                }
                try await self.sessionDisplay.execute(accepted.command.name)
            } catch {
                failure = RemoteError(
                    code: "session_control_unconfirmed", message: error.localizedDescription)
            }
            guard self.clients[id] === client, !Task.isCancelled else { return }
            client.peer.send(session.makeResult(for: accepted, error: failure))
        }
    }
}
