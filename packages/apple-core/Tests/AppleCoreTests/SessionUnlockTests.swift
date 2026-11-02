import XCTest
@testable import AppleCore

final class SessionUnlockTests: XCTestCase {
    func testUnlockHasNoPayloadAndCannotCarryInputOrVolume() throws {
        try RemoteCommand(name: .sessionUnlock).validate()
        for command in [
            RemoteCommand(name: .sessionUnlock, x: 1),
            RemoteCommand(name: .sessionUnlock, text: "text"),
            RemoteCommand(name: .sessionUnlock, key: .returnKey),
            RemoteCommand(name: .sessionUnlock, value: 1)
        ] {
            XCTAssertThrowsError(try command.validate())
        }
    }

    func testUnlockDeadlineDoesNotChangeInputDeadline() {
        let connection = UUID().uuidString
        let request = UUID().uuidString
        let unlock = PendingCommandMetadata(
            connectionID: connection, requestID: request, sequence: 1,
            command: RemoteCommand(name: .sessionUnlock))
        let input = PendingCommandMetadata(
            connectionID: connection, requestID: request, sequence: 2,
            command: RemoteCommand(name: .pointerMove, x: 1, y: 1))
        XCTAssertEqual(unlock.timeoutSeconds, 12)
        XCTAssertEqual(input.timeoutSeconds, 3)
    }

    func testOldStateDecodesWithoutUnlockSupport() throws {
        let bytes = Data("{\"accessibilityGranted\":true,\"deviceName\":\"Mac\"}".utf8)
        let state = try JSONDecoder().decode(RemoteState.self, from: bytes)
        XCTAssertNil(state.sessionLocked)
        XCTAssertNil(state.unlockAvailable)
    }
}
