import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import UnlockNative

public enum NativeUnlockTrigger {
    @MainActor public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @MainActor public static func requestAccessibilityIfNeeded() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return AXIsProcessTrusted()
    }

    /// Submit one neutral Return pair only at the empty, focused system secure
    /// password control. The authorization plug-in supplies the approval.
    @MainActor public static func perform() async throws {
        let state = SRReadConsole()
        guard SRUnlockEligible(state), state.userID == getuid()
        else {
            throw UnlockFailure.consoleUnavailable
        }
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw UnlockFailure.accessibilityRequired
        }
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.loginwindow")
        guard applications.count == 1, let application = applications.first,
            application.executableURL?.path
                == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        else { throw UnlockFailure.passwordControlUnavailable }
        let identifier = application.processIdentifier
        let expectedSession = fingerprint(state)
        let currentNames = [NSFullUserName(), NSUserName()]
        let operation = Task.detached(priority: .userInitiated) {
            try await prepare(
                process: identifier, expectedSession: expectedSession, currentNames: currentNames)
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private static func prepare(
        process: pid_t, expectedSession: Data, currentNames: [String]
    ) async throws {
        try await NativeUnlockPreparation.run(
            .init(
                now: { SRContinuousTime() },
                validate: {
                    try validateConsole(
                        expectedSession: expectedSession, deadline: .infinity)
                },
                wake: {
                    var assertion = IOPMAssertionID(kIOPMNullAssertionID)
                    // A local-style display wake is intentional: authentication needs
                    // loginwindow's visible secure control, even for a remote request.
                    guard
                        IOPMAssertionDeclareUserActivity(
                            "Sofa Remote authorized unlock" as CFString,
                            kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess
                    else { throw UnlockFailure.displayWakeUnavailable }
                    return { _ = IOPMAssertionRelease(assertion) }
                },
                find: { deadline in
                    try NativeUnlockDiscovery.find(
                        process: process, currentNames: currentNames, deadline: deadline)
                },
                selectUser: { control, deadline in
                    try NativeUnlockDiscovery.selectUser(
                        control, process: process, currentNames: currentNames,
                        validateContext: {
                            try validateConsole(
                                expectedSession: expectedSession, deadline: deadline)
                        })
                },
                submit: { control, deadline in
                    let root = AXUIElementCreateApplication(process)
                    AXUIElementSetMessagingTimeout(root, 0.05)
                    try activateControl(
                        control.element, root: root, process: process,
                        expectedSession: expectedSession, deadline: deadline)
                },
                pause: { try await Task.sleep(for: .milliseconds(100)) }))
    }

    private static func activateControl(
        _ element: AXUIElement, root: AXUIElement, process: pid_t,
        expectedSession: Data, deadline: TimeInterval
    ) throws {
        var count: CFTypeRef?
        let countStatus = AXUIElementCopyAttributeValue(
            element, kAXNumberOfCharactersAttribute as CFString, &count)
        let number = count.flatMap {
            CFGetTypeID($0) == CFNumberGetTypeID() ? $0 as? NSNumber : nil
        }
        let control = NativeUnlockControlSnapshot(
            identifier: stringAttribute(element, kAXIdentifierAttribute as CFString),
            role: stringAttribute(element, kAXRoleAttribute as CFString),
            subrole: stringAttribute(element, kAXSubroleAttribute as CFString),
            countStatus: countStatus, characterCount: number?.intValue,
            enabled: booleanAttribute(element, kAXEnabledAttribute as CFString),
            focused: booleanAttribute(element, kAXFocusedAttribute as CFString),
            matchesFocusedElement: matchesFocus(element, root: root, process: process))
        // Build both events before any empty write or keyboard dispatch.
        guard let events = NativeUnlockReturnPair() else { throw UnlockFailure.triggerUnavailable }
        try NativeUnlockControlPolicy.activate(
            control,
            validateContext: {
                try validateConsole(expectedSession: expectedSession, deadline: deadline)
                guard booleanAttribute(element, kAXEnabledAttribute as CFString),
                    booleanAttribute(element, kAXFocusedAttribute as CFString),
                    matchesFocus(element, root: root, process: process),
                    CGPreflightPostEventAccess(), SRContinuousTime() < deadline
                else { throw UnlockFailure.passwordControlUnavailable }
                try validateConsole(expectedSession: expectedSession, deadline: deadline)
            },
            clear: { try clearControl(element) },
            submit: { events.post() })
    }

    private static func validateConsole(expectedSession: Data, deadline: TimeInterval) throws {
        try Task.checkCancellation()
        let current = SRReadConsole()
        guard SRContinuousTime() < deadline,
            SRUnlockEligible(current), current.userID == getuid(),
            fingerprint(current) == expectedSession
        else { throw UnlockFailure.consoleUnavailable }
    }

    private static func fingerprint(_ state: SRConsoleSnapshot) -> Data {
        var state = state
        var result = withUnsafeBytes(of: &state.sessionUUID) { Data($0) }
        result.append(withUnsafeBytes(of: &state.bootUUID) { Data($0) })
        return result
    }

    private static func matchesFocus(
        _ element: AXUIElement, root: AXUIElement, process: pid_t
    ) -> Bool {
        var owner: pid_t = -1
        var focused: CFTypeRef?
        return AXUIElementGetPid(element, &owner) == .success && owner == process
            && AXUIElementCopyAttributeValue(
                root, kAXFocusedUIElementAttribute as CFString, &focused) == .success
            && focused.map { CFEqual($0, element) } == true
    }

    private static func booleanAttribute(_ element: AXUIElement, _ name: CFString) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
            let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return value as? Bool == true
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

struct NativeUnlockReturnPair {
    private let source: CGEventSource
    let down: CGEvent
    let up: CGEvent

    init?() {
        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        else { return nil }
        self.source = source
        self.down = down
        self.up = up
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }
    }

    func post() {
        withExtendedLifetime(source) {
            down.post(tap: .cghidEventTap)
            // Release the key without a cancellation point after key-down.
            up.post(tap: .cghidEventTap)
        }
    }
}
