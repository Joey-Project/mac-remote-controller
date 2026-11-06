import XCTest
@testable import AppleCore

final class SessionControlTests: XCTestCase {
    private let commands: [CommandName] = [
        .sessionLock, .displayOff, .displayWake, .sessionLockAndDisplayOff
    ]

    func testControlsHaveNoPayloadAndRoundTripWithExactNames() throws {
        for name in commands {
            let command = RemoteCommand(name: name)
            try command.validate()
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteCommand.self, from: JSONEncoder().encode(command)),
                command)
            for invalid in [
                RemoteCommand(name: name, value: 1), RemoteCommand(name: name, text: "input"),
                RemoteCommand(name: name, x: 1), RemoteCommand(name: name, key: .returnKey),
                RemoteCommand(name: name, shortcut: .missionControl),
                RemoteCommand(name: name, tapTimestamp: 1)
            ] { XCTAssertThrowsError(try invalid.validate()) }
        }
    }

    func testLockAndDisplayActionsAreMutuallyExclusiveAcrossAllKnownStates() {
        for locked in [false, true] {
            for asleep in [false, true] {
                let state = state(locked: locked, asleep: asleep)
                XCTAssertEqual(SessionControlPolicy.allows(.sessionLock, state: state), !locked)
                XCTAssertEqual(SessionControlPolicy.allows(.sessionUnlock, state: state), locked)
                XCTAssertEqual(SessionControlPolicy.allows(.displayOff, state: state), !asleep)
                XCTAssertEqual(SessionControlPolicy.allows(.displayWake, state: state), asleep)
                XCTAssertEqual(
                    SessionControlPolicy.allows(.sessionLockAndDisplayOff, state: state),
                    !(locked && asleep))
            }
        }
    }

    func testMissingCapabilityOrUnknownStateCannotEnableActions() {
        var unknown = state(locked: nil, asleep: nil)
        for command in commands + [.sessionUnlock] {
            XCTAssertFalse(SessionControlPolicy.allows(command, state: unknown))
        }
        unknown = state(locked: false, asleep: false)
        unknown.capabilities = nil
        for command in commands {
            XCTAssertFalse(SessionControlPolicy.allows(command, state: unknown))
        }
    }

    func testLockAndDisplayDoNotDependOnUnlockHelperOrAccessibility() {
        var state = state(locked: false, asleep: false)
        state.accessibilityGranted = false
        state.unlockAvailable = false
        state.capabilities = [WireCapabilities.remoteLock, WireCapabilities.displayPower]
        for command in [CommandName.sessionLock, .displayOff, .sessionLockAndDisplayOff] {
            XCTAssertTrue(SessionControlPolicy.allows(command, state: state))
        }
        XCTAssertFalse(SessionControlPolicy.allows(.sessionUnlock, state: state))
    }

    func testKnownDisplayCannotEnableControlsForAnUnknownConsoleSession() {
        XCTAssertFalse(
            SessionControlPolicy.allows(.displayOff, state: state(locked: nil, asleep: false)))
        XCTAssertFalse(
            SessionControlPolicy.allows(.displayWake, state: state(locked: nil, asleep: true)))
    }

    func testOldStateHasUnknownDisplayAndNewStateRoundTrips() throws {
        let old = try JSONDecoder().decode(
            RemoteState.self,
            from: Data(
                "{\"accessibilityGranted\":true,\"deviceName\":\"Mac\"}".utf8))
        XCTAssertNil(old.displayAsleep)
        let current = state(locked: true, asleep: true)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteState.self, from: JSONEncoder().encode(current)), current
        )
    }

    func testNewControlsHaveBoundedDeadlinesWithoutChangingInput() {
        for name in commands {
            let metadata = PendingCommandMetadata(
                connectionID: "connection", requestID: "request", sequence: 1,
                command: .init(name: name))
            XCTAssertEqual(metadata.timeoutSeconds, 10)
        }
    }

    private func state(locked: Bool?, asleep: Bool?) -> RemoteState {
        RemoteState(
            accessibilityGranted: true, systemVolume: nil, deviceName: "Mac",
            capabilities: [
                WireCapabilities.remoteUnlock, WireCapabilities.remoteLock,
                WireCapabilities.displayPower
            ],
            sessionLocked: locked, unlockAvailable: true, displayAsleep: asleep)
    }
}
