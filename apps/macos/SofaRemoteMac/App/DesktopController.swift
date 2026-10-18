import AppKit
import AppleCore
@preconcurrency import ApplicationServices
import CoreAudio

@MainActor
final class DesktopController {
    var state: RemoteState {
        let volume = SystemVolume.read()
        return RemoteState(
            accessibilityGranted: AXIsProcessTrusted(), systemVolume: volume.value,
            systemVolumeReason: volume.reason, deviceName: Host.current().localizedName ?? "Mac")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func execute(_ command: RemoteCommand) throws {
        try command.validate()
        if command.name == .systemVolumeSet {
            let value = try require(command.value)
            try SystemVolume.set(value)
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
            let x = try require(command.x)
            let y = try require(command.y)
            try post(
                CGEvent(
                    scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: Int32(y), wheel2: Int32(x), wheel3: 0))
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

private enum SystemVolume {
    static func read() -> (value: Double?, reason: String?) {
        guard let device = outputDevice(), let elements = volumeElements(device) else {
            return (nil, ControlError.volumeUnavailable.localizedDescription)
        }
        var values: [Float32] = []
        for element in elements {
            var address = volumeAddress(element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
                value.isFinite, (0...1).contains(value)
            else { return (nil, ControlError.volumeUnavailable.localizedDescription) }
            values.append(value)
        }
        return (Double(values.reduce(0, +) / Float32(values.count)), nil)
    }

    static func set(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value), let device = outputDevice(),
            let elements = volumeElements(device)
        else { throw ControlError.volumeUnavailable }
        for element in elements {
            var address = volumeAddress(element)
            var scalar = Float32(value)
            guard
                AudioObjectSetPropertyData(
                    device, &address, 0, nil,
                    UInt32(MemoryLayout<Float32>.size), &scalar) == noErr
            else { throw ControlError.volumeUnavailable }
        }
    }

    private static func outputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                0, nil, &size, &device) == noErr, device != 0
        else { return nil }
        return device
    }

    private static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement]? {
        if writable(device, element: 0) { return [0] }
        guard let count = outputChannelCount(device), (1...64).contains(count) else { return nil }
        let elements = (1...count).map { AudioObjectPropertyElement($0) }
        return elements.allSatisfy { writable(device, element: $0) } ? elements : nil
    }

    private static func outputChannelCount(_ device: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size >= MemoryLayout<AudioBufferList>.size, size <= 65_536
        else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func writable(_ device: AudioObjectID, element: AudioObjectPropertyElement)
        -> Bool
    {
        var address = volumeAddress(element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func volumeAddress(_ element: AudioObjectPropertyElement)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}
