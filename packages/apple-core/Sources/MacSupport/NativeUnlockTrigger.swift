import AppKit
@preconcurrency import ApplicationServices
import UnlockNative

public enum NativeUnlockTrigger {
    @MainActor public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @MainActor public static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return AXIsProcessTrusted()
    }

    /// Confirm only the system secure password control. Never read its value,
    /// supply a password, send key events, or select a button by its title.
    @MainActor public static func perform() async throws {
        let state = SRReadConsole()
        guard state.known, state.loggedIn, state.locked, state.userID == getuid()
        else {
            throw UnlockFailure.consoleUnavailable
        }
        guard AXIsProcessTrusted() else { throw UnlockFailure.accessibilityRequired }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.loginwindow")
        guard applications.count == 1, let application = applications.first,
            application.executableURL?.path
                == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        else { throw UnlockFailure.passwordControlUnavailable }
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
                try activateControl(element, identifier: identifier as? String, deadline: deadline)
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
        throw UnlockFailure.passwordControlUnavailable
    }

    private static func activateControl(
        _ element: AXUIElement, identifier: String?, deadline: TimeInterval
    ) throws {
        var count: CFTypeRef?
        let countStatus = AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &count)
        let number = count.flatMap {
            CFGetTypeID($0) == CFNumberGetTypeID() ? $0 as? NSNumber : nil
        }
        var actions: CFArray?
        let actionStatus = AXUIElementCopyActionNames(element, &actions)
        let control = NativeUnlockControlSnapshot(
            identifier: identifier,
            role: stringAttribute(element, kAXRoleAttribute as CFString),
            subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
            countStatus: countStatus, characterCount: number?.intValue,
            supportsConfirm: actionStatus == .success
                && (actions as? [String])?.contains(kAXConfirmAction) == true)
        try NativeUnlockControlPolicy.activate(
            control,
            validateContext: {
                try Task.checkCancellation()
                let current = SRReadConsole()
                guard ProcessInfo.processInfo.systemUptime < deadline,
                    current.known, current.loggedIn, current.locked, current.userID == getuid()
                else { throw UnlockFailure.consoleUnavailable }
            },
            clear: { try clearControl(element) },
            confirm: {
                try NativeUnlockControlPolicy.checkConfirmationReply(
                    AXUIElementPerformAction(element, kAXConfirmAction as CFString))
            })
    }

    private static func clearControl(_ element: AXUIElement) throws {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { throw UnlockFailure.passwordControlNotWritable }
        guard
            AXUIElementSetAttributeValue(
                element, kAXValueAttribute as CFString, "" as CFString) == .success
        else { throw UnlockFailure.passwordControlClearFailed }
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }
}
