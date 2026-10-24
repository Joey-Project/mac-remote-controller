import AppKit
import AppleCore
@preconcurrency import ApplicationServices
import MacSupport

struct DesktopInputState {
    var scrollAccumulator = PixelScrollAccumulator()
    var heldInput = HeldInputState()
    var clickTracker = PointerClickTracker()
}

@MainActor
final class DesktopController {
    private let volumeController = SystemVolumeController()

    var state: RemoteState {
        let volume = volumeController.read()
        return RemoteState(
            accessibilityGranted: AXIsProcessTrusted(), systemVolume: volume.value,
            systemVolumeReason: volume.reason,
            deviceName: DeviceName.bounded(Host.current().localizedName ?? "", fallback: "Mac"),
            supportsGestures: true)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func execute(_ command: RemoteCommand, input: inout DesktopInputState) throws {
        try command.validate()
        if command.name == .systemVolumeSet {
            let value = try require(command.value)
            try volumeController.set(value)
            return
        }
        guard AXIsProcessTrusted() else { throw ControlError.accessibilityDenied }
        guard let source = CGEventSource(stateID: .hidSystemState),
            let location = CGEvent(source: nil)?.location
        else { throw ControlError.eventUnavailable }
        switch command.name {
        case .pointerMove, .pointerClick, .pointerScroll, .pointerButtonDown, .pointerButtonUp:
            try executePointer(
                command, source: source, location: location,
                input: &input)
        case .keyboardText, .keyboardKey:
            try executeKeyboard(command, source: source)
        case .systemShortcut:
            try perform(command.shortcut, source: source)
        case .systemVolumeSet:
            break
        }
    }

    private func executePointer(
        _ command: RemoteCommand, source: CGEventSource, location: CGPoint,
        input: inout DesktopInputState
    ) throws {
        switch command.name {
        case .pointerMove:
            try move(command, source: source, location: location, held: input.heldInput)
        case .pointerClick:
            let button = try require(command.button)
            let clickState = input.clickTracker.register(
                button: button, x: location.x, y: location.y,
                at: command.tapTimestamp ?? ProcessInfo.processInfo.systemUptime,
                doubleClickInterval: NSEvent.doubleClickInterval,
                timebase: command.tapTimestamp == nil ? .server : .client)
            try click(button: button, clickState: clickState, source: source, location: location)
        case .pointerScroll:
            try emitScroll(command, source: source, accumulator: &input.scrollAccumulator)
        case .pointerButtonDown, .pointerButtonUp:
            try setPointerButton(
                command, source: source, location: location, held: &input.heldInput)
        default:
            throw ControlError.invalidCommand
        }
    }

    private func setPointerButton(
        _ command: RemoteCommand, source: CGEventSource, location: CGPoint,
        held: inout HeldInputState
    ) throws {
        let button = try require(command.button)
        let isDown = command.name == .pointerButtonDown
        if isDown == held.buttons.contains(button) { return }
        try post(mouseEvent(button: button, down: isDown, source: source, location: location))
        _ = held.apply(command)
    }

    private func executeKeyboard(_ command: RemoteCommand, source: CGEventSource) throws {
        switch command.name {
        case .keyboardText:
            try type(require(command.text), source: source)
        case .keyboardKey:
            let key = try require(command.key)
            try post(CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true))
            try post(CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false))
        default:
            throw ControlError.invalidCommand
        }
    }

    func release(_ held: inout HeldInputState) {
        release(held.releaseAll())
    }

    func release(_ buttons: [PointerButton]) {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let location = CGEvent(source: nil)?.location
        else { return }
        for button in buttons {
            try? post(mouseEvent(button: button, down: false, source: source, location: location))
        }
    }

    private func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw ControlError.invalidCommand }
        return value
    }

    private func move(
        _ command: RemoteCommand, source: CGEventSource, location: CGPoint,
        held: HeldInputState
    ) throws {
        guard let x = command.x, let y = command.y else { throw ControlError.invalidCommand }
        let dragButton = held.dragButton
        let mouseType: CGEventType =
            switch dragButton {
            case .left: .leftMouseDragged
            case .right: .rightMouseDragged
            case nil: .mouseMoved
            }
        let button: CGMouseButton = dragButton == .right ? .right : .left
        try post(
            CGEvent(
                mouseEventSource: source, mouseType: mouseType,
                mouseCursorPosition: CGPoint(x: location.x + x, y: location.y + y),
                mouseButton: button))
    }

    private func mouseEvent(
        button: PointerButton, down: Bool, source: CGEventSource, location: CGPoint
    ) -> CGEvent? {
        let type: CGEventType =
            switch (button, down) {
            case (.left, true): .leftMouseDown
            case (.left, false): .leftMouseUp
            case (.right, true): .rightMouseDown
            case (.right, false): .rightMouseUp
            }
        return CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
            mouseButton: button == .left ? .left : .right)
    }

    private func perform(_ shortcut: SystemShortcut?, source: CGEventSource) throws {
        guard let shortcut else { throw ControlError.invalidCommand }
        let key: CGKeyCode =
            switch shortcut {
            case .missionControl: 126  // Control-Up
            case .appExpose: 125  // Control-Down
            case .previousSpace: 123  // Control-Left
            case .nextSpace: 124  // Control-Right
            }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            else { throw ControlError.eventUnavailable }
            event.flags = .maskControl
            event.post(tap: .cghidEventTap)
        }
    }

    private func emitScroll(
        _ command: RemoteCommand,
        source: CGEventSource,
        accumulator: inout PixelScrollAccumulator
    ) throws {
        let pixels = try accumulator.consume(x: require(command.x), y: require(command.y))
        guard pixels.x != 0 || pixels.y != 0 else { return }
        try post(
            CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: pixels.y, wheel2: pixels.x, wheel3: 0))
    }

    private func click(
        button: PointerButton, clickState: Int, source: CGEventSource, location: CGPoint
    ) throws {
        for isDown in [true, false] {
            let type: CGEventType =
                switch (button, isDown) {
                case (.left, true): .leftMouseDown
                case (.left, false): .leftMouseUp
                case (.right, true): .rightMouseDown
                case (.right, false): .rightMouseUp
                }
            guard
                let event = CGEvent(
                    mouseEventSource: source, mouseType: type,
                    mouseCursorPosition: location, mouseButton: button == .left ? .left : .right)
            else { throw ControlError.eventUnavailable }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            event.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String, source: CGEventSource) throws {
        // Keep surrogate pairs together while respecting CGEvent's 20-unit text limit.
        var units = Array(text.utf16)
        while !units.isEmpty {
            var count = min(20, units.count)
            if count < units.count, (0xD800...0xDBFF).contains(units[count - 1]) { count -= 1 }
            var chunk = Array(units.prefix(count))
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                else { throw ControlError.eventUnavailable }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.post(tap: .cghidEventTap)
            }
            units.removeFirst(count)
        }
    }

    private func post(_ event: CGEvent?) throws {
        guard let event else { throw ControlError.eventUnavailable }
        event.post(tap: .cghidEventTap)
    }
}

private extension RemoteKey {
    var code: CGKeyCode {
        switch self {
        case .returnKey: 36
        case .escape: 53
        case .backspace: 51
        case .space: 49
        case .left: 123
        case .right: 124
        case .down: 125
        case .up: 126
        }
    }
}

enum ControlError: Error, LocalizedError {
    case accessibilityDenied
    case eventUnavailable
    case invalidCommand

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Allow Sofa Remote in System Settings → Privacy & Security → Accessibility."
        case .eventUnavailable: "macOS could not create an input event."
        case .invalidCommand: "The command is invalid."
        }
    }
}
