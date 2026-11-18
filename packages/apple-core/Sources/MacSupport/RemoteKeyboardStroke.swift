import AppleCore
import CoreGraphics

/// A fixed key stroke with no session-owned modifier state or modifier key-down events.
public struct RemoteKeyboardStroke {
    public let keyCode: CGKeyCode
    public let modifiers: CGEventFlags

    private static let keyCodes: [RemoteKey: CGKeyCode] = [
        .returnKey: 36, .escape: 53, .backspace: 51, .space: 49,
        .left: 123, .right: 124, .down: 125, .up: 126,
        .tab: 48, .forwardDelete: 117, .home: 115, .end: 119, .pageUp: 116, .pageDown: 121
    ]

    public init(key: RemoteKey) {
        guard let code = Self.keyCodes[key] else {
            preconditionFailure("Every allowlisted RemoteKey must have a native mapping.")
        }
        keyCode = code
        modifiers = []
    }

    public init(shortcut: RemoteKeyboardShortcut) {
        switch shortcut {
        case .copy: keyCode = 8; modifiers = .maskCommand
        case .cut: keyCode = 7; modifiers = .maskCommand
        case .paste: keyCode = 9; modifiers = .maskCommand
        case .selectAll: keyCode = 0; modifiers = .maskCommand
        case .undo: keyCode = 6; modifiers = .maskCommand
        case .redo: keyCode = 6; modifiers = [.maskCommand, .maskShift]
        case .find: keyCode = 3; modifiers = .maskCommand
        case .previousField: keyCode = 48; modifiers = .maskShift
        }
    }

    /// Prepare both events before posting. The up event explicitly clears remote flags.
    @discardableResult
    public func emit(post: (CGEvent) -> Void) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        return KeyboardEventPair.emit(
            create: { CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: $0) },
            configure: { event, isDown in event.flags = isDown ? modifiers : [] },
            post: post)
    }
}
