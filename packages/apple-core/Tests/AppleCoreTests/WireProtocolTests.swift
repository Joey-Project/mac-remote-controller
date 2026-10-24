import Foundation
import XCTest
@testable import AppleCore

final class WireProtocolTests: XCTestCase {
    func testSharedFixtureDecodesAndRoundTrips() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "pointer-move", withExtension: "json", subdirectory: "Fixtures"))
        let decoded = try WireCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(decoded.type, .command)
        XCTAssertEqual(decoded.command, RemoteCommand(name: .pointerMove, x: 125.5, y: -48.25))
        XCTAssertEqual(try WireCodec.decode(WireCodec.encode(decoded)), decoded)
    }

    func testRejectsUnsupportedVersionAndUnknownCommandBeforeExecution() throws {
        let unsupportedJSON = #"""
            {
              "protocolVersion": 2,
              "type": "state",
              "connectionId": "c",
              "state": { "accessibilityGranted": false, "deviceName": "Mac" }
            }
            """#
        let unsupported = Data(unsupportedJSON.utf8)
        XCTAssertThrowsError(try WireCodec.decode(unsupported)) { error in
            XCTAssertEqual(error as? WireProtocolError, .unsupportedVersion(2))
        }

        let unknownCommandJSON = #"""
            {
              "protocolVersion": 1,
              "type": "command",
              "connectionId": "c",
              "requestId": "7be3f81c-f579-42f3-b9fb-2fc322939b86",
              "sequence": 1,
              "command": { "name": "shell.run", "text": "ignored" }
            }
            """#
        let unknownCommand = Data(unknownCommandJSON.utf8)
        XCTAssertThrowsError(try WireCodec.decode(unknownCommand))
    }

    func testWelcomeRequiresStateAndRoundTripsValidState() throws {
        let missingStateJSON = #"""
            {
              "protocolVersion": 1,
              "type": "welcome",
              "connectionId": "connection-example"
            }
            """#
        XCTAssertThrowsError(try WireCodec.decode(Data(missingStateJSON.utf8)))

        let missingState = WireMessage(type: .welcome, connectionID: "connection-example")
        XCTAssertThrowsError(try WireCodec.encode(missingState))

        let welcome = WireMessage(
            type: .welcome,
            connectionID: "connection-example",
            state: RemoteState(
                accessibilityGranted: true,
                systemVolume: nil,
                systemVolumeReason: "Unavailable",
                deviceName: "Living Room Mac"
            )
        )
        XCTAssertEqual(try WireCodec.decode(WireCodec.encode(welcome)), welcome)
    }

    func testRejectsOversizedMessageAndMalformedEnvelope() throws {
        XCTAssertThrowsError(
            try WireCodec.decode(Data(repeating: 0x20, count: WireLimits.maximumMessageBytes + 1)))
        let missingIdentity = WireMessage(
            type: .command, command: RemoteCommand(name: .pointerMove, x: 1, y: 2))
        XCTAssertThrowsError(try WireCodec.encode(missingIdentity))
    }

    func testUnicodeCommittedTextUsesUTF8ByteLimit() throws {
        let unicode = "你好 👋 café"
        let command = RemoteCommand(name: .keyboardText, text: unicode)
        try command.validate()
        XCTAssertGreaterThan(unicode.utf8.count, unicode.count)

        let tooLong = RemoteCommand(
            name: .keyboardText,
            text: String(repeating: "界", count: WireLimits.maximumTextBytes / 3 + 1))
        XCTAssertThrowsError(try tooLong.validate())
        XCTAssertThrowsError(try RemoteCommand(name: .keyboardText, text: "").validate())
    }

    func testRejectsNonFiniteAndOutOfRangeValues() throws {
        XCTAssertThrowsError(
            try RemoteCommand(name: .pointerClick, x: 1, y: 2, button: .left).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .pointerMove, x: .nan, y: 0).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .pointerMove, x: 500.01, y: 0).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .pointerScroll, x: 101, y: 0).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .systemVolumeSet, value: 1.01).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .systemVolumeSet, value: .infinity).validate())
    }

    func testGestureCommandsAreAllowlistedAndRejectExtraFields() throws {
        try RemoteCommand(name: .pointerButtonDown, button: .left).validate()
        try RemoteCommand(name: .pointerButtonUp, button: .left).validate()
        try RemoteCommand(name: .systemShortcut, shortcut: .missionControl).validate()
        XCTAssertThrowsError(try RemoteCommand(name: .pointerButtonDown).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .systemShortcut).validate())
        XCTAssertThrowsError(try RemoteCommand(name: .systemShortcut, key: .up).validate())
        XCTAssertThrowsError(
            try RemoteCommand(name: .pointerButtonDown, text: "bad", button: .left).validate())
    }

    func testGestureCapabilityIsBackwardCompatibleWhenAbsent() throws {
        let legacyJSON = #"{"accessibilityGranted":true,"deviceName":"Mac"}"#
        let state = try JSONDecoder().decode(RemoteState.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(state.supportsGestures)
        let capable = RemoteState(
            accessibilityGranted: true, systemVolume: nil,
            deviceName: "Mac", supportsGestures: true,
            capabilities: [WireCapabilities.roundTripProbe])
        let decoded = try JSONDecoder().decode(
            RemoteState.self,
            from: JSONEncoder().encode(capable))
        XCTAssertTrue(decoded.supportsGestures == true)
        XCTAssertEqual(decoded.capabilities, [WireCapabilities.roundTripProbe])
    }

    func testSessionRejectsWrongConnectionAndReplayButAllowsGaps() throws {
        var session = ServerSession(connectionID: "connection-a")
        let command = RemoteCommand(name: .pointerClick, button: .left)
        let first = try makeCommand(connectionID: "connection-a", sequence: 4, command: command)
        let accepted = try session.accept(first)
        XCTAssertEqual(accepted.sequence, 4)
        XCTAssertEqual(session.makeResult(for: accepted).requestID, accepted.requestID)

        XCTAssertThrowsError(try session.accept(first)) { error in
            XCTAssertEqual(error as? WireProtocolError, .invalidSequence(expected: 5, received: 4))
        }
        let wrongConnection = try makeCommand(
            connectionID: "connection-b", sequence: 5, command: command)
        XCTAssertThrowsError(try session.accept(wrongConnection)) { error in
            XCTAssertEqual(error as? WireProtocolError, .invalidConnectionID)
        }
        XCTAssertEqual(session.lastSequence, 4)

        let withGap = try makeCommand(connectionID: "connection-a", sequence: 9, command: command)
        XCTAssertEqual(try session.accept(withGap).sequence, 9)
    }

    func testInvalidCommandConsumesSequenceThenAllowsNextControl() throws {
        var session = ServerSession(connectionID: "connection-a")
        let invalid = try makeCommand(
            connectionID: "connection-a",
            sequence: 1,
            command: RemoteCommand(name: .systemVolumeSet, value: 2)
        )
        XCTAssertThrowsError(try session.accept(invalid))
        XCTAssertEqual(session.lastSequence, 1)

        let next = try makeCommand(
            connectionID: "connection-a",
            sequence: 2,
            command: RemoteCommand(name: .systemVolumeSet, value: 0.5)
        )
        XCTAssertEqual(try session.accept(next).sequence, 2)
    }

    private func makeCommand(
        connectionID: String,
        sequence: UInt64,
        command: RemoteCommand
    ) throws -> WireMessage {
        WireMessage(
            type: .command,
            connectionID: connectionID,
            requestID: UUID().uuidString,
            sequence: sequence,
            command: command
        )
    }
}
