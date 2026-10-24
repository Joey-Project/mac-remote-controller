import AppleCore
import Foundation

extension CompanionModel {
    func retryPendingHeldInputReleases() {
        for id in Array(pendingHeldInputReleases.keys) {
            guard var held = pendingHeldInputReleases[id] else { continue }
            desktop.release(&held)
            if held.buttons.isEmpty {
                pendingHeldInputReleases.removeValue(forKey: id)
                if heldPointerOwner == id { heldPointerOwner = nil }
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
        do {
            try desktop.execute(command, input: &client.inputState)
            client.inputState.heldInput.refresh()
            if command.name == .pointerButtonDown, !client.inputState.heldInput.buttons.isEmpty {
                heldPointerOwner = id
            }
            if command.name == .pointerButtonUp, client.inputState.heldInput.buttons.isEmpty {
                heldPointerOwner = nil
            }
            return nil
        } catch {
            return RemoteError(code: "control_unavailable", message: error.localizedDescription)
        }
    }
}
