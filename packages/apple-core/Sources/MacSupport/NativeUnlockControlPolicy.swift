@preconcurrency import ApplicationServices

struct NativeUnlockControlSnapshot {
    var identifier: String?
    var role: String?
    var subrole: String?
    var countStatus: AXError
    var characterCount: Int?
    var enabled: Bool
    var focused: Bool
    var matchesFocusedElement: Bool
}

enum NativeUnlockControlPolicy {
    static func activate(
        _ control: NativeUnlockControlSnapshot,
        validateContext: () throws -> Void,
        clear: () throws -> Void,
        submit: () throws -> Void
    ) throws {
        guard control.identifier == "UserPasswordTextField", control.role == kAXTextFieldRole,
            control.subrole == kAXSecureTextFieldSubrole,
            control.enabled, control.focused, control.matchesFocusedElement
        else { throw UnlockFailure.passwordControlUnavailable }

        let needsClearing: Bool
        switch control.countStatus {
        case .success:
            guard let count = control.characterCount, count >= 0 else {
                throw UnlockFailure.passwordControlUnavailable
            }
            guard count == 0 else { throw UnlockFailure.passwordFieldNotEmpty }
            needsClearing = false
        case .attributeUnsupported:
            // The system secure field may omit character-count metadata.
            // Establish emptiness by a successful empty write, never a value read.
            needsClearing = true
        default:
            throw UnlockFailure.passwordControlUnavailable
        }

        if needsClearing {
            try validateContext()
            try clear()
        }
        try validateContext()
        try submit()
    }
}
