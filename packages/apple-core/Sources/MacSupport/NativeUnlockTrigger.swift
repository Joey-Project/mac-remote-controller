import AppKit
@preconcurrency import ApplicationServices
import UnlockNative

public enum NativeUnlockTrigger {
    /// Confirm only an empty native login password control. Never read or write
    /// its text, send key events, or press an arbitrary button by its title.
    @MainActor public static func perform() async throws {
        let state = SRReadConsole()
        guard state.known, state.loggedIn, state.locked, state.userID == getuid(),
            AXIsProcessTrusted()
        else {
            throw UnlockFailure.triggerUnavailable
        }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.loginwindow")
        guard applications.count == 1, let application = applications.first,
            application.executableURL?.path
                == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        else { throw UnlockFailure.triggerUnavailable }
        let identifier = application.processIdentifier
        let operation = Task.detached(priority: .userInitiated) { try confirm(process: identifier) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func confirm(process: pid_t) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        let root = AXUIElementCreateApplication(process)
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 128, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let element = queue.removeFirst()
            AXUIElementSetMessagingTimeout(element, 0.05)
            visited += 1
            var identifier: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                element, kAXIdentifierAttribute as CFString, &identifier) == .success,
                identifier as? String == "UserPasswordTextField"
            {
                var count: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(
                        element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
                    let number = count as? NSNumber, number.intValue == 0
                else { throw UnlockFailure.triggerUnavailable }
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                    (actions as? [String])?.contains(kAXConfirmAction) == true
                else {
                    throw UnlockFailure.triggerUnavailable
                }
                try Task.checkCancellation()
                let current = SRReadConsole()
                guard current.known, current.loggedIn, current.locked, current.userID == getuid(),
                    AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success
                else {
                    throw UnlockFailure.triggerUnavailable
                }
                return
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                == .success,
                let elements = children as? [AXUIElement]
            {
                queue.append(contentsOf: elements.prefix(max(0, 128 - visited - queue.count)))
            }
        }
        throw UnlockFailure.triggerUnavailable
    }
}
