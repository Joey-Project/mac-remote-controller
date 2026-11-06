import Foundation

/// Retries discovery only. User selection and authentication are each attempted once.
enum NativeUnlockPreparation {
    enum Step<Control> {
        case password(Control)
        case userSelection(Control)
    }

    struct Operations<Control> {
        var now: () -> TimeInterval
        var validate: () throws -> Void
        var wake: () throws -> (() -> Void)
        var find: (TimeInterval) throws -> Step<Control>?
        var selectUser: (Control, TimeInterval) throws -> Void
        var submit: (Control, TimeInterval) throws -> Void
        var pause: () async throws -> Void
    }

    static func run<Control>(_ operations: Operations<Control>) async throws {
        try Task.checkCancellation()
        try operations.validate()
        let deadline = operations.now() + 3
        let release = try operations.wake()
        defer { release() }
        var selectedUser = false
        while operations.now() < deadline {
            try Task.checkCancellation()
            try operations.validate()
            if let step = try operations.find(deadline) {
                try Task.checkCancellation()
                try operations.validate()
                guard operations.now() < deadline else {
                    throw UnlockFailure.passwordControlUnavailable
                }
                switch step {
                case .password(let control):
                    try operations.submit(control, deadline)
                    return
                case .userSelection(let control) where !selectedUser:
                    selectedUser = true
                    try operations.selectUser(control, deadline)
                case .userSelection:
                    break
                }
            }
            try await operations.pause()
        }
        throw UnlockFailure.passwordControlUnavailable
    }
}
