import CoreAudio
import XCTest
@testable import MacSupport

@MainActor
final class SystemVolumeControllerTests: XCTestCase {
    func testReadReportsZeroWhenMuteIsEnabledEvenWithNonzeroScalarVolume() {
        let audioIO = FakeCoreAudioIO(volume: 0.72, mute: .value(true))
        let controller = SystemVolumeController(audioIO: audioIO)

        let result = controller.read()

        XCTAssertEqual(result.value, 0)
        XCTAssertNil(result.reason)
    }

    func testReadonlyMutedOutputReportsVolumeUnavailable() {
        let audioIO = FakeCoreAudioIO(volume: 0.72, mute: .value(true), muteWritable: false)
        let controller = SystemVolumeController(audioIO: audioIO)

        let result = controller.read()

        XCTAssertNil(result.value)
        XCTAssertNotNil(result.reason)
    }

    func testReadonlyUnmutedOutputRemainsSupported() {
        let audioIO = FakeCoreAudioIO(volume: 0.42, mute: .value(false), muteWritable: false)
        let controller = SystemVolumeController(audioIO: audioIO)

        let result = controller.read()

        XCTAssertEqual(result.value ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertNil(result.reason)
    }

    func testNonzeroWriteUpdatesScalarAndClearsCurrentMute() throws {
        let audioIO = FakeCoreAudioIO(volume: 0.2, mute: .value(true))
        let controller = SystemVolumeController(audioIO: audioIO)

        try controller.set(0.65)

        XCTAssertEqual(audioIO.volumes[0] ?? -1, Float32(0.65), accuracy: 0.0001)
        XCTAssertEqual(audioIO.mute, .value(false))
        XCTAssertEqual(audioIO.writeOrder, ["volume:0", "mute:false"])
    }

    func testReadonlyMutedOutputRejectsWriteBeforeChangingScalar() {
        let audioIO = FakeCoreAudioIO(volume: 0.37, mute: .value(true), muteWritable: false)
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertThrowsError(try controller.set(0.9))
        XCTAssertEqual(audioIO.volumes[0], 0.37)
        XCTAssertEqual(audioIO.volumeWriteCount, 0)
    }

    func testZeroWritePreservesExistingMute() throws {
        let audioIO = FakeCoreAudioIO(volume: 0.37, mute: .value(true), muteWritable: false)
        let controller = SystemVolumeController(audioIO: audioIO)

        try controller.set(0)

        XCTAssertEqual(audioIO.volumes[0], 0)
        XCTAssertEqual(audioIO.mute, .value(true))
        XCTAssertEqual(audioIO.muteWriteCount, 0)
    }

    func testChannelFallbackWritesTheSameScalarToEveryOutputChannel() throws {
        let audioIO = FakeCoreAudioIO(volume: 0.37, mute: .unsupported, elements: [1, 2])
        let controller = SystemVolumeController(audioIO: audioIO)

        try controller.set(0.8)

        XCTAssertEqual(audioIO.volumes[1] ?? -1, Float32(0.8), accuracy: 0.0001)
        XCTAssertEqual(audioIO.volumes[2] ?? -1, Float32(0.8), accuracy: 0.0001)
        XCTAssertEqual(audioIO.volumeWriteCount, 2)
    }

    func testLaterChannelWriteFailureRestoresAlreadyWrittenChannel() {
        let audioIO = FakeCoreAudioIO(
            volumes: [1: 0.2, 2: 0.7], mute: .unsupported, failedWriteAttempts: [2: [1]])
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertThrowsError(try controller.set(0.8)) { error in
            guard
                case SystemVolumeControllerError.volumeWriteFailed(
                    element: 2, rollbackFailedElements: []) = error
            else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(audioIO.volumes[1], 0.2)
        XCTAssertEqual(audioIO.volumes[2], 0.7)
        XCTAssertEqual(audioIO.writeOrder, ["volume:1", "volume:2", "volume:1"])
    }

    func testFailedChannelSnapshotPreventsAllWrites() {
        let audioIO = FakeCoreAudioIO(
            volumes: [1: 0.2, 2: 0.7], mute: .unsupported, unreadableElements: [2])
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertThrowsError(try controller.set(0.8))

        XCTAssertTrue(audioIO.writeOrder.isEmpty)
        XCTAssertEqual(audioIO.volumes[1], 0.2)
        XCTAssertEqual(audioIO.volumes[2], 0.7)
    }

    func testRollbackFailureReportsBothFailedWriteAndUnrestoredChannel() {
        let audioIO = FakeCoreAudioIO(
            volumes: [1: 0.2, 2: 0.7], mute: .unsupported,
            failedWriteAttempts: [1: [2], 2: [1]])
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertThrowsError(try controller.set(0.8)) { error in
            guard
                case SystemVolumeControllerError.volumeWriteFailed(
                    element: 2, rollbackFailedElements: [1]) = error
            else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(audioIO.volumes[1], 0.8)
        XCTAssertEqual(audioIO.volumes[2], 0.7)
    }

    func testUnmuteFailureRestoresChannelVolumesAndPreservesMuteFailure() {
        let audioIO = FakeCoreAudioIO(
            volumes: [1: 0.2, 2: 0.7], mute: .value(true), failedMuteWrite: true)
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertThrowsError(try controller.set(0.8)) { error in
            guard
                case SystemVolumeControllerError.muteWriteFailed(rollbackFailedElements: []) = error
            else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(audioIO.volumes[1], 0.2)
        XCTAssertEqual(audioIO.volumes[2], 0.7)
        XCTAssertEqual(audioIO.mute, .value(true))
    }

    func testOutputWithoutMutePropertyRetainsScalarVolumeSupport() throws {
        let audioIO = FakeCoreAudioIO(volume: 0.3, mute: .unsupported)
        let controller = SystemVolumeController(audioIO: audioIO)

        XCTAssertEqual(controller.read().value ?? -1, 0.3, accuracy: 0.0001)
        try controller.set(0.8)
        XCTAssertEqual(audioIO.volumes[0] ?? -1, Float32(0.8), accuracy: 0.0001)
        XCTAssertEqual(audioIO.muteWriteCount, 0)
    }

    func testMuteQueryFailureReportsUnavailableAndRejectsWrites() {
        let audioIO = FakeCoreAudioIO(volume: 0.3, mute: .unavailable)
        let controller = SystemVolumeController(audioIO: audioIO)

        let result = controller.read()

        XCTAssertNil(result.value)
        XCTAssertNotNil(result.reason)
        XCTAssertThrowsError(try controller.set(0.8))
        XCTAssertEqual(audioIO.volumeWriteCount, 0)
    }
}

private final class FakeCoreAudioIO: CoreAudioIO {
    private(set) var volumes: [AudioObjectPropertyElement: Float32]
    var mute: MutePropertyRead
    var muteWritable: Bool
    private let failedMuteWrite: Bool
    private let unreadableElements: Set<AudioObjectPropertyElement>
    private let failedWriteAttempts: [AudioObjectPropertyElement: Set<Int>]
    private var writeAttempts: [AudioObjectPropertyElement: Int] = [:]
    private(set) var volumeWriteCount = 0
    private(set) var muteWriteCount = 0
    private(set) var writeOrder: [String] = []

    init(
        volume: Float32,
        mute: MutePropertyRead,
        muteWritable: Bool = true,
        elements: [AudioObjectPropertyElement] = [0]
    ) {
        self.volumes = Dictionary(uniqueKeysWithValues: elements.map { ($0, volume) })
        unreadableElements = []
        failedWriteAttempts = [:]
        failedMuteWrite = false
        self.mute = mute
        self.muteWritable = muteWritable
    }

    init(
        volumes: [AudioObjectPropertyElement: Float32],
        mute: MutePropertyRead,
        muteWritable: Bool = true,
        unreadableElements: Set<AudioObjectPropertyElement> = [],
        failedWriteAttempts: [AudioObjectPropertyElement: Set<Int>] = [:],
        failedMuteWrite: Bool = false
    ) {
        self.volumes = volumes
        self.unreadableElements = unreadableElements
        self.failedWriteAttempts = failedWriteAttempts
        self.failedMuteWrite = failedMuteWrite
        self.mute = mute
        self.muteWritable = muteWritable
    }

    func defaultOutputDevice() -> AudioObjectID? { 1 }

    func volumeElements(for device: AudioObjectID) -> [AudioObjectPropertyElement]? {
        guard device == 1 else { return nil }
        return Array(volumes.keys).sorted()
    }

    func readVolume(device: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        guard device == 1, !unreadableElements.contains(element) else { return nil }
        return volumes[element]
    }

    func writeVolume(device: AudioObjectID, element: AudioObjectPropertyElement, value: Float32)
        -> Bool
    {
        guard device == 1, volumes[element] != nil else { return false }
        let attempt = (writeAttempts[element] ?? 0) + 1
        writeAttempts[element] = attempt
        writeOrder.append("volume:\(element)")
        guard !failedWriteAttempts[element, default: []].contains(attempt) else { return false }
        volumes[element] = value
        volumeWriteCount += 1
        return true
    }

    func readMute(device: AudioObjectID) -> MutePropertyRead {
        device == 1 ? mute : .unavailable
    }

    func canWriteMute(device: AudioObjectID) -> Bool {
        device == 1 && muteWritable
    }

    func writeMute(device: AudioObjectID, muted: Bool) -> Bool {
        guard device == 1, muteWritable, !failedMuteWrite else { return false }
        mute = .value(muted)
        muteWriteCount += 1
        writeOrder.append("mute:\(muted)")
        return true
    }
}
