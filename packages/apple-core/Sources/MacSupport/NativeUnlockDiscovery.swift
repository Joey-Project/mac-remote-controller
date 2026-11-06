@preconcurrency import ApplicationServices
import UnlockNative

/// System loginwindow controls only; no account labels or secure values are logged.
enum NativeUnlockDiscovery {
    struct Control {
        let element: AXUIElement
        var userList: AXUIElement?
    }

    private struct Entry {
        let element: AXUIElement
        var userList: AXUIElement?
    }

    static func find(
        process: pid_t, currentNames: [String], deadline: TimeInterval
    ) throws -> NativeUnlockPreparation.Step<Control>? {
        let root = AXUIElementCreateApplication(process)
        var queue = [Entry(element: root)]
        var seen: [AXUIElement] = []
        var lists: [AXUIElement] = []
        var buttons: [(Control, NativeUnlockUserButtonSnapshot)] = []
        var complete = true
        while !queue.isEmpty, seen.count < 128, SRContinuousTime() < deadline {
            try Task.checkCancellation()
            var entry = queue.removeFirst()
            let element = entry.element
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            seen.append(element)
            AXUIElementSetMessagingTimeout(element, 0.05)
            let identifier = string(element, kAXIdentifierAttribute)
            let role = string(element, kAXRoleAttribute)
            if entry.userList != nil, role == nil { complete = false }
            if passwordReady(element, identifier: identifier, root: root, process: process) {
                return .password(Control(element: element))
            }
            if isCollection(element, identifier: identifier, role: role) {
                lists.append(element)
                entry.userList = element
            }
            if entry.userList != nil, role == kAXButtonRole {
                buttons.append(
                    (Control(element: element, userList: entry.userList), snapshot(element)))
            }
            let children = descendants(of: entry, limit: max(0, 128 - seen.count - queue.count))
            complete = complete && children.complete
            queue.append(contentsOf: children.entries)
        }
        guard lists.count == 1, let list = lists.first else { return nil }
        let candidates = buttons.filter { $0.0.userList.map { CFEqual($0, list) } == true }
        guard
            let index = NativeUnlockUserSelectionPolicy.candidate(
                in: candidates.map(\.1), currentNames: currentNames,
                collectionReady: collectionReady(list, root: root, process: process),
                traversalComplete: complete && queue.isEmpty && SRContinuousTime() < deadline)
        else { return nil }
        return .userSelection(candidates[index].0)
    }

    static func selectUser(
        _ control: Control, process: pid_t, currentNames: [String],
        validateContext: () throws -> Void
    ) throws {
        let root = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let list = control.userList,
            collectionReady(list, root: root, process: process),
            owns(control.element, process: process),
            NativeUnlockUserSelectionPolicy.candidate(
                in: [snapshot(control.element)], currentNames: currentNames,
                collectionReady: true, traversalComplete: true) == 0
        else { throw UnlockFailure.passwordControlUnavailable }
        try validateContext()
        try NativeUnlockUserSelectionPolicy.validateActionResult(
            AXUIElementPerformAction(control.element, kAXPressAction as CFString))
    }

    private static func descendants(of entry: Entry, limit: Int) -> (
        entries: [Entry], complete: Bool
    ) {
        var children: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            entry.element, kAXChildrenAttribute as CFString, &children)
        switch status {
        case .success:
            guard let values = children as? [AXUIElement] else { return ([], false) }
            return (
                values.prefix(limit).map { Entry(element: $0, userList: entry.userList) },
                values.count <= limit
            )
        case .attributeUnsupported, .noValue: return ([], true)
        default: return ([], false)
        }
    }

    private static func isCollection(_ element: AXUIElement, identifier: String?, role: String?)
        -> Bool
    {
        identifier == "UserCollectionView" && role == kAXListRole
            && string(element, kAXSubroleAttribute) == "AXCollectionList"
    }

    private static func passwordReady(
        _ element: AXUIElement, identifier: String?, root: AXUIElement, process: pid_t
    ) -> Bool {
        identifier == "UserPasswordTextField" && boolean(element, kAXEnabledAttribute)
            && boolean(element, kAXFocusedAttribute)
            && matchesFocus(element, root: root, process: process)
    }

    private static func collectionReady(
        _ element: AXUIElement, root: AXUIElement, process: pid_t
    ) -> Bool {
        string(element, kAXIdentifierAttribute) == "UserCollectionView"
            && string(element, kAXRoleAttribute) == kAXListRole
            && string(element, kAXSubroleAttribute) == "AXCollectionList"
            && boolean(element, kAXEnabledAttribute) && boolean(element, kAXFocusedAttribute)
            && matchesFocus(element, root: root, process: process)
    }

    private static func snapshot(_ element: AXUIElement) -> NativeUnlockUserButtonSnapshot {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
        let enabled = value.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0 as? Bool : nil }
        var actions: CFArray?
        let actionsStatus = AXUIElementCopyActionNames(element, &actions)
        return NativeUnlockUserButtonSnapshot(
            identifier: string(element, kAXIdentifierAttribute),
            role: string(element, kAXRoleAttribute),
            enabledStatus: status, enabled: enabled,
            supportsPress: actionsStatus == .success
                && (actions as? [String])?.contains(kAXPressAction) == true)
    }

    private static func owns(_ element: AXUIElement, process: pid_t) -> Bool {
        var owner: pid_t = -1
        return AXUIElementGetPid(element, &owner) == .success && owner == process
    }

    private static func matchesFocus(_ element: AXUIElement, root: AXUIElement, process: pid_t)
        -> Bool
    {
        var focused: CFTypeRef?
        return owns(element, process: process)
            && AXUIElementCopyAttributeValue(
                root, kAXFocusedUIElementAttribute as CFString, &focused) == .success
            && focused.map { CFEqual($0, element) } == true
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolean(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
            let value, CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return false }
        return value as? Bool == true
    }
}
