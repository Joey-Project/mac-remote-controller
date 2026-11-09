import AppleCore
import Foundation

extension CompanionModel {
    func cancelGesturesForTermination() -> Bool {
        for client in clients.values { desktop.cancelGesture(&client.inputState.gesture) }
        retryPendingHeldInputReleases()
        guard pendingGestureReleases.isEmpty,
            clients.values.allSatisfy({ !$0.inputState.gesture.isActive })
        else {
            errorMessage =
                "The gesture could not be cancelled. Restore Accessibility access and quit again."
            return false
        }
        return true
    }

    func releaseExpiredInput(at now: TimeInterval) {
        for (id, client) in clients {
            if client.inputState.gesture.expired(at: now) {
                desktop.cancelGesture(&client.inputState.gesture)
            }
            let expired = client.inputState.heldInput.expiredButtons(ifOlderThan: 8, now: now)
            if !expired.isEmpty { desktop.release(expired, from: &client.inputState.heldInput) }
            if !client.inputState.hasHeldInput, heldPointerOwner == id { heldPointerOwner = nil }
        }
    }

    func retryPendingHeldInputReleases() {
        for id in Array(pendingGestureReleases.keys) {
            guard var gesture = pendingGestureReleases[id] else { continue }
            desktop.cancelGesture(&gesture)
            if gesture.isActive {
                pendingGestureReleases[id] = gesture
            } else {
                pendingGestureReleases.removeValue(forKey: id)
                if pendingHeldInputReleases[id] == nil, heldPointerOwner == id {
                    heldPointerOwner = nil
                }
            }
        }
        for id in Array(pendingHeldInputReleases.keys) {
            guard var held = pendingHeldInputReleases[id] else { continue }
            desktop.release(&held)
            if held.buttons.isEmpty {
                pendingHeldInputReleases.removeValue(forKey: id)
                if pendingGestureReleases[id] == nil, heldPointerOwner == id {
                    heldPointerOwner = nil
                }
            } else {
                pendingHeldInputReleases[id] = held
            }
        }
    }
}

extension CompanionModel {
    func execute(_ command: RemoteCommand, for client: ClientConnection, id: UUID)
        -> RemoteError?
    {
        if PointerOwnershipPolicy.blocks(command, heldBy: heldPointerOwner, requester: id) {
            return RemoteError(
                code: "pointer_busy", message: "Another remote session is holding the pointer.")
        }
        if command.name == .systemShortcut, let owner = heldPointerOwner,
            clients[owner]?.inputState.gesture.isActive == true
                || pendingGestureReleases[owner] != nil
        {
            return RemoteError(code: "pointer_busy", message: "A touch gesture is still active.")
        }
        do {
            try desktop.execute(command, input: &client.inputState)
            client.inputState.heldInput.refresh()
            if client.inputState.hasHeldInput {
                heldPointerOwner = id
            }
            if !client.inputState.hasHeldInput, heldPointerOwner == id {
                heldPointerOwner = nil
            }
            return nil
        } catch {
            return RemoteError(code: "control_unavailable", message: error.localizedDescription)
        }
    }
}
