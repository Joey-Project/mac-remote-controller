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

    func testRejectedDragStartWithAndWithoutQueuedReleaseNeverRequiresTeardown() {
        var withoutRelease = PointerDragResultPolicy()
        withoutRelease.begin(gestureID: "drag-a")
        withoutRelease.registerStart(gestureID: "drag-a", requestID: "down-a")
        XCTAssertEqual(
            withoutRelease.acceptResult(requestID: "down-a", succeeded: false),
            .startRejected(gestureID: "drag-a"))
        XCTAssertTrue(withoutRelease.isEmpty)

        var withRelease = PointerDragResultPolicy()
        withRelease.begin(gestureID: "drag-b")
        withRelease.registerStart(gestureID: "drag-b", requestID: "down-b")
        withRelease.expectRelease(gestureID: "drag-b")
        withRelease.registerRelease(gestureID: "drag-b", requestID: "up-b")
        XCTAssertEqual(
            withRelease.acceptResult(requestID: "down-b", succeeded: false),
            .startRejected(gestureID: "drag-b"))
        XCTAssertEqual(
            withRelease.acceptResult(requestID: "up-b", succeeded: false),
            .releaseFailureSuppressed(gestureID: "drag-b"))
        XCTAssertTrue(withRelease.isEmpty)
    }

    func testEarlyReleaseFailureWaitsForDragStartResult() {
        var rejectedStart = PointerDragResultPolicy()
        rejectedStart.begin(gestureID: "drag-rejected")
        rejectedStart.registerStart(gestureID: "drag-rejected", requestID: "down-rejected")
        rejectedStart.expectRelease(gestureID: "drag-rejected")
        rejectedStart.registerRelease(gestureID: "drag-rejected", requestID: "up-rejected")
        XCTAssertEqual(
            rejectedStart.acceptResult(requestID: "up-rejected", succeeded: false),
            .releaseFailureDeferred(gestureID: "drag-rejected"))
        XCTAssertEqual(
            rejectedStart.acceptResult(requestID: "down-rejected", succeeded: false),
            .releaseFailureSuppressed(gestureID: "drag-rejected"))

        var acceptedStart = PointerDragResultPolicy()
        acceptedStart.begin(gestureID: "drag-accepted")
        acceptedStart.registerStart(gestureID: "drag-accepted", requestID: "down-accepted")
        acceptedStart.expectRelease(gestureID: "drag-accepted")
        acceptedStart.registerRelease(gestureID: "drag-accepted", requestID: "up-accepted")
        XCTAssertEqual(
            acceptedStart.acceptResult(requestID: "up-accepted", succeeded: false),
            .releaseFailureDeferred(gestureID: "drag-accepted"))
        XCTAssertEqual(
            acceptedStart.acceptResult(requestID: "down-accepted", succeeded: true),
            .releaseFailureRequiresSessionTeardown(gestureID: "drag-accepted"))
        XCTAssertTrue(acceptedStart.isEmpty)
    }

    func testAcceptedDragStartStillRequiresTeardownForFailedRelease() {
        var policy = PointerDragResultPolicy()
        policy.begin(gestureID: "drag-a")
        policy.registerStart(gestureID: "drag-a", requestID: "down-a")
        policy.expectRelease(gestureID: "drag-a")
        policy.registerRelease(gestureID: "drag-a", requestID: "up-a")

        XCTAssertEqual(
            policy.acceptResult(requestID: "down-a", succeeded: true),
            .startAccepted(gestureID: "drag-a"))
        XCTAssertEqual(
            policy.acceptResult(requestID: "up-a", succeeded: false),
            .releaseFailureRequiresSessionTeardown(gestureID: "drag-a"))
        XCTAssertTrue(policy.isEmpty)
    }
}
