import AppleCore
import XCTest

final class RemoteControlPolicyTests: XCTestCase {
    func testFailedReleaseTeardownRequiresMatchingResultIdentity() {
        let command = RemoteCommand(name: .pointerButtonUp, button: .left)
        let metadata = PendingCommandMetadata(
            connectionID: "connection-a", requestID: "request-a", sequence: 12,
            command: command)
        let failure = WireMessage(
            type: .result, connectionID: "connection-a", requestID: "request-a",
            sequence: 12,
            error: RemoteError(code: "control_unavailable", message: "Release failed."))

        XCTAssertTrue(metadata.matchesResult(failure))
        XCTAssertTrue(metadata.requiresSessionTeardown(for: failure))

        let success = WireMessage(
            type: .result, connectionID: "connection-a", requestID: "request-a",
            sequence: 12)
        XCTAssertTrue(metadata.matchesResult(success))
        XCTAssertFalse(metadata.requiresSessionTeardown(for: success))

        let wrongSequence = WireMessage(
            type: .result, connectionID: "connection-a", requestID: "request-a",
            sequence: 13,
            error: RemoteError(code: "control_unavailable", message: "Release failed."))
        let wrongRequest = WireMessage(
            type: .result, connectionID: "connection-a", requestID: "request-b",
            sequence: 12,
            error: RemoteError(code: "control_unavailable", message: "Release failed."))
        XCTAssertFalse(metadata.matchesResult(wrongSequence))
        XCTAssertFalse(metadata.requiresSessionTeardown(for: wrongSequence))
        XCTAssertFalse(metadata.matchesResult(wrongRequest))
        XCTAssertFalse(metadata.requiresSessionTeardown(for: wrongRequest))

        let ordinaryControl = PendingCommandMetadata(
            connectionID: "connection-a", requestID: "request-a", sequence: 12,
            command: RemoteCommand(name: .pointerMove, x: 1, y: 0))
        XCTAssertFalse(ordinaryControl.requiresSessionTeardown(for: failure))
    }

    func testSecondClientShortcutBypassesPointerLockButPointerCommandsRemainBlocked() {
        let pointerOwner = UUID()
        let otherClient = UUID()
        let pointerCommands = [
            RemoteCommand(name: .pointerMove, x: 1, y: 0),
            RemoteCommand(name: .pointerClick, button: .left),
            RemoteCommand(name: .pointerScroll, x: 0, y: 1),
            RemoteCommand(name: .pointerButtonDown, button: .left),
            RemoteCommand(name: .pointerButtonUp, button: .left)
        ]

        for command in pointerCommands {
            XCTAssertTrue(
                PointerOwnershipPolicy.blocks(
                    command, heldBy: pointerOwner, requester: otherClient),
                "\(command.name.rawValue) must remain owned by the first client")
            XCTAssertFalse(
                PointerOwnershipPolicy.blocks(
                    command, heldBy: pointerOwner, requester: pointerOwner))
            XCTAssertFalse(
                PointerOwnershipPolicy.blocks(command, heldBy: nil, requester: otherClient))
        }

        let shortcut = RemoteCommand(name: .systemShortcut, shortcut: .missionControl)
        XCTAssertFalse(
            PointerOwnershipPolicy.blocks(
                shortcut, heldBy: pointerOwner, requester: otherClient))
    }
}
