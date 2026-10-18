import AppKit
import AppleCore
@preconcurrency import ApplicationServices
import MacSupport

@MainActor
final class DesktopController {
    private let volumeController = SystemVolumeController()

    var state: RemoteState {
        let volume = volumeController.read()
        return RemoteState(
            accessibilityGranted: AXIsProcessTrusted(), systemVolume: volume.value,
            systemVolumeReason: volume.reason, deviceName: Host.current().localizedName ?? "Mac")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func execute(_ command: RemoteCommand, scroll: inout PixelScrollAccumulator) throws {
        try command.validate()
        if command.name == .systemVolumeSet {
            let value = try require(command.value)
            do { try volumeController.set(value) } catch { throw ControlError.volumeUnavailable }
            return
        }
        guard AXIsProcessTrusted() else { throw ControlError.accessibilityDenied }
        guard let source = CGEventSource(stateID: .hidSystemState),
            let location = CGEvent(source: nil)?.location
        else { throw ControlError.eventUnavailable }
        switch command.name {
        case .pointerMove:
            try move(command, source: source, location: location)
        case .pointerClick:
            try click(right: command.button == .right, source: source, location: location)
        case .pointerScroll:
            try emitScroll(command, source: source, accumulator: &scroll)
        case .keyboardText:
            try type(require(command.text), source: source)
        case .keyboardKey:
            let key = try require(command.key)
            try post(CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true))
            try post(CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false))
        case .systemVolumeSet: break
        }
    }

    private func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw ControlError.invalidCommand }
        return value
    }

    private func move(_ command: RemoteCommand, source: CGEventSource, location: CGPoint) throws {
        guard let x = command.x, let y = command.y else { throw ControlError.invalidCommand }
        try post(
            CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: location.x + x, y: location.y + y),
                mouseButton: .left))
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

    private func click(right: Bool, source: CGEventSource, location: CGPoint) throws {
        try post(
            CGEvent(
                mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                mouseCursorPosition: location, mouseButton: right ? .right : .left))
        try post(
            CGEvent(
                mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                mouseCursorPosition: location, mouseButton: right ? .right : .left))
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
    case volumeUnavailable
    case invalidCommand

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Allow Sofa Remote in System Settings → Privacy & Security → Accessibility."
        case .eventUnavailable: "macOS could not create an input event."
        case .volumeUnavailable: "The current audio output does not support system volume control."
        case .invalidCommand: "The command is invalid."
        }
    }
}
