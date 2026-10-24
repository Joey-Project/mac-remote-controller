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
