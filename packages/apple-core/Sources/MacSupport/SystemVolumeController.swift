import CoreAudio
import Foundation

enum MutePropertyRead: Equatable {
    case unsupported
    case value(Bool)
    case unavailable
}

protocol CoreAudioIO {
    func defaultOutputDevice() -> AudioObjectID?
    func volumeElements(for device: AudioObjectID) -> [AudioObjectPropertyElement]?
    func readVolume(device: AudioObjectID, element: AudioObjectPropertyElement) -> Float32?
    func writeVolume(device: AudioObjectID, element: AudioObjectPropertyElement, value: Float32)
        -> Bool
    func readMute(device: AudioObjectID) -> MutePropertyRead
    func canWriteMute(device: AudioObjectID) -> Bool
    func writeMute(device: AudioObjectID, muted: Bool) -> Bool
}

public enum SystemVolumeControllerError: Error, LocalizedError, Sendable {
    case unavailable
    case invalidValue
    case volumeWriteFailed(element: UInt32, rollbackFailedElements: [UInt32])
    case muteWriteFailed(rollbackFailedElements: [UInt32])

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The current audio output does not support system volume control."
        case .invalidValue:
            "The system volume value is invalid."
        case .volumeWriteFailed(_, let rollbackFailedElements):
            if rollbackFailedElements.isEmpty {
                "The system volume could not be changed."
            } else {
                "The system volume changed only partly and could not be fully restored. "
                    + "Check the output volume on your Mac."
            }
        case .muteWriteFailed(let rollbackFailedElements):
            if rollbackFailedElements.isEmpty {
                "The system volume mute state could not be updated."
            } else {
                "The output mute state could not be updated, and its previous volume could not be fully restored. "
                    + "Check the output volume on your Mac."
            }
        }
    }
}

/// Reads and writes the default output device's system volume and mute state.
@MainActor
public final class SystemVolumeController {
    private let audioIO: any CoreAudioIO

    public init() {
        audioIO = CoreAudioDeviceIO()
    }

    init(audioIO: any CoreAudioIO) {
        self.audioIO = audioIO
    }

    public func read() -> (value: Double?, reason: String?) {
        guard let device = audioIO.defaultOutputDevice(),
            let elements = audioIO.volumeElements(for: device), !elements.isEmpty
        else {
            return unavailableRead()
        }

        switch audioIO.readMute(device: device) {
        case .unavailable:
            return unavailableRead()
        case .value(true):
            guard audioIO.canWriteMute(device: device) else { return unavailableRead() }
            return (0, nil)
        case .unsupported, .value(false):
            break
        }

        var values: [Float32] = []
        values.reserveCapacity(elements.count)
        for element in elements {
            guard let value = audioIO.readVolume(device: device, element: element),
                value.isFinite, (0...1).contains(value)
            else { return unavailableRead() }
            values.append(value)
        }
        return (Double(values.reduce(0, +) / Float32(values.count)), nil)
    }

    public func set(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw SystemVolumeControllerError.invalidValue
        }
        guard let device = audioIO.defaultOutputDevice(),
            let elements = audioIO.volumeElements(for: device), !elements.isEmpty
        else { throw SystemVolumeControllerError.unavailable }

        let isMuted: Bool
        switch audioIO.readMute(device: device) {
        case .unsupported:
            isMuted = false
        case .value(let muted):
            isMuted = muted
        case .unavailable:
            throw SystemVolumeControllerError.unavailable
        }

        let shouldUnmute = isMuted && value > 0
        if shouldUnmute && !audioIO.canWriteMute(device: device) {
            throw SystemVolumeControllerError.unavailable
        }

        let originalValues = try snapshotVolumes(device: device, elements: elements)

        var writtenElements: [AudioObjectPropertyElement] = []
        for element in elements {
            guard audioIO.writeVolume(device: device, element: element, value: Float32(value))
            else {
                let rollbackFailures = restoreVolumes(
                    device: device, elements: writtenElements, originalValues: originalValues)
                throw SystemVolumeControllerError.volumeWriteFailed(
                    element: UInt32(element),
                    rollbackFailedElements: rollbackFailures)
            }
            writtenElements.append(element)
        }

        if shouldUnmute && !audioIO.writeMute(device: device, muted: false) {
            let rollbackFailures = restoreVolumes(
                device: device, elements: writtenElements, originalValues: originalValues)
            throw SystemVolumeControllerError.muteWriteFailed(
                rollbackFailedElements: rollbackFailures)
        }
    }

    private func snapshotVolumes(
        device: AudioObjectID, elements: [AudioObjectPropertyElement]
    ) throws -> [AudioObjectPropertyElement: Float32] {
        var originalValues: [AudioObjectPropertyElement: Float32] = [:]
        originalValues.reserveCapacity(elements.count)
        for element in elements {
            guard let value = audioIO.readVolume(device: device, element: element),
                value.isFinite, (0...1).contains(value)
            else { throw SystemVolumeControllerError.unavailable }
            originalValues[element] = value
        }
        return originalValues
    }

    private func restoreVolumes(
        device: AudioObjectID,
        elements: [AudioObjectPropertyElement],
        originalValues: [AudioObjectPropertyElement: Float32]
    ) -> [AudioObjectPropertyElement] {
        var failedElements: [AudioObjectPropertyElement] = []
        for element in elements.reversed() {
            guard let originalValue = originalValues[element],
                audioIO.writeVolume(device: device, element: element, value: originalValue)
            else {
                failedElements.append(element)
                continue
            }
        }
        return failedElements
    }

    private func unavailableRead() -> (value: Double?, reason: String?) {
        (nil, SystemVolumeControllerError.unavailable.localizedDescription)
    }
}

private struct CoreAudioDeviceIO: CoreAudioIO {
    func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
            ) == noErr, device != 0
        else { return nil }
        return device
    }

    func volumeElements(for device: AudioObjectID) -> [AudioObjectPropertyElement]? {
        if writableVolume(device, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        guard let count = outputChannelCount(device), (1...64).contains(count) else { return nil }
        let elements = (1...count).map(AudioObjectPropertyElement.init)
        return elements.allSatisfy { writableVolume(device, element: $0) } ? elements : nil
    }

    func readVolume(device: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    func writeVolume(device: AudioObjectID, element: AudioObjectPropertyElement, value: Float32)
        -> Bool
    {
        var address = volumeAddress(element)
        var scalar = value
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
        ) == noErr
    }

    func readMute(device: AudioObjectID) -> MutePropertyRead {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return .unsupported }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            value <= 1
        else { return .unavailable }
        return .value(value == 1)
    }

    func canWriteMute(device: AudioObjectID) -> Bool {
        var address = muteAddress
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    func writeMute(device: AudioObjectID, muted: Bool) -> Bool {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    private func writableVolume(_ device: AudioObjectID, element: AudioObjectPropertyElement)
        -> Bool
    {
        var address = volumeAddress(element)
        var settable = DarwinBoolean(false)
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    private func outputChannelCount(_ device: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
            size >= MemoryLayout<AudioBufferList>.size, size <= 65_536
        else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return nil
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func volumeAddress(
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
