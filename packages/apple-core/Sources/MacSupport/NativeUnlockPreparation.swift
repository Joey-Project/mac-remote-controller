import Foundation

/// Retries discovery only. Once a control is selected, submission is never replayed.
enum NativeUnlockPreparation {
    struct Operations<Control> {
        var now: () -> TimeInterval
        var validate: () throws -> Void
        var wake: () throws -> (() -> Void)
        var find: (TimeInterval) throws -> Control?
        var submit: (Control, TimeInterval) throws -> Void
        var pause: () async throws -> Void
    }

    static func run<Control>(_ operations: Operations<Control>) async throws {
        try Task.checkCancellation()
        try operations.validate()
        let deadline = operations.now() + 3
        let release = try operations.wake()
        defer { release() }
        while operations.now() < deadline {
            try Task.checkCancellation()
            try operations.validate()
            if let control = try operations.find(deadline) {
                try Task.checkCancellation()
                try operations.validate()
                guard operations.now() < deadline else {
                    throw UnlockFailure.passwordControlUnavailable
                }
                try operations.submit(control, deadline)
                return
            }
            try await operations.pause()
        }
        throw UnlockFailure.passwordControlUnavailable
    }
}
