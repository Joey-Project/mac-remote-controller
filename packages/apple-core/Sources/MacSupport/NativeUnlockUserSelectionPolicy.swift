@preconcurrency import ApplicationServices

struct NativeUnlockUserButtonSnapshot {
    var identifier: String?
    var role: String?
    var enabledStatus: AXError
    var enabled: Bool?
    var supportsPress: Bool
}

enum NativeUnlockUserSelectionPolicy {
    static func validateActionResult(_ status: AXError) throws {
        // A messaging timeout can follow a completed native action. Do not replay
        // it: continue discovery, which must independently find the secure field.
        guard status == .success || status == .cannotComplete else {
            throw UnlockFailure.passwordControlUnavailable
        }
    }

    static func candidate(
        in buttons: [NativeUnlockUserButtonSnapshot], currentNames: [String],
        collectionReady: Bool, traversalComplete: Bool
    ) -> Int? {
        guard collectionReady, traversalComplete,
            buttons.allSatisfy({ $0.identifier != nil && $0.role != nil })
        else { return nil }
        let identifiers = Set(
            currentNames.filter { !$0.isEmpty }.map { "User: \($0); LoggedIn: logged in" })
        let matches = buttons.indices.filter {
            buttons[$0].identifier.map { identifiers.contains($0) } == true
        }
        guard matches.count == 1, let index = matches.first else { return nil }
        let button = buttons[index]
        guard button.role == kAXButtonRole, button.supportsPress else { return nil }
        switch button.enabledStatus {
        case .success: return button.enabled == true ? index : nil
        case .attributeUnsupported: return index
        default: return nil
        }
    }
}
