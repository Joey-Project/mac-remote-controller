import AppleCore
import XCTest

final class MediaProtocolTests: XCTestCase {
    func testLegacyStateWithoutMediaTargetsRemainsValidAndUnspecified() throws {
        let data = Data(
            #"{"accessibilityGranted":true,"systemVolume":0.5,"deviceName":"Mac"}"#.utf8)
        let state = try JSONDecoder().decode(RemoteState.self, from: data)

        XCTAssertNil(state.mediaTargets)
        XCTAssertNoThrow(try state.validate())
    }

    func testMediaCommandRoundTripsExactTargetAndCapabilities() throws {
        let target = MediaTarget(
            id: "iina:window-7", name: "IINA · Episode 4", kind: .iina,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: true, previous: false,
                playerVolumeMaximum: 1.5))
        let command = RemoteCommand(
            name: .mediaControl,
            mediaRequest: MediaRequest(targetID: target.id, action: .seek, value: -10))
        let state = RemoteState(
            accessibilityGranted: true, systemVolume: 0.5, deviceName: "Mac",
            mediaTargets: [target])
        let message = WireMessage(
            type: .command, connectionID: "connection", requestID: UUID().uuidString,
            sequence: 1, command: command)

        try state.validate()
        let decodedCommand = try WireCodec.decode(WireCodec.encode(message)).command

        XCTAssertEqual(decodedCommand, command)
        XCTAssertEqual(state.mediaTargets?.first?.id, "iina:window-7")
        XCTAssertEqual(state.mediaTargets?.first?.capabilities.playerVolumeMaximum, 1.5)
    }

    func testSharedMediaCommandFixtureDecodesAndRoundTrips() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "media-control", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try Data(contentsOf: url)
        let decoded = try WireCodec.decode(fixture)
        let encoded = try WireCodec.encode(decoded)

        XCTAssertEqual(decoded.command?.name, .mediaControl)
        XCTAssertEqual(decoded.command?.mediaRequest?.targetID, "chrome:42")
        XCTAssertEqual(decoded.command?.mediaRequest?.value, -10)
        XCTAssertEqual(try WireCodec.decode(encoded), decoded)
    }

    func testMediaControlRejectsMissingRequestAndExtraneousCommandFields() {
        XCTAssertThrowsError(try RemoteCommand(name: .mediaControl).validate())
        XCTAssertThrowsError(
            try RemoteCommand(
                name: .mediaControl, value: 0.5,
                mediaRequest: MediaRequest(targetID: "tab:8", action: .playPause)
            ).validate())
        XCTAssertThrowsError(
            try RemoteCommand(
                name: .systemVolumeSet, value: 0.5,
                mediaRequest: MediaRequest(targetID: "tab:8", action: .playPause)
            ).validate())
    }

    func testMediaRequestAndCommandRejectUnknownWireFields() {
        let extraRequestField = Data(
            #"{"name":"media.control","mediaRequest":{"targetId":"chrome:7","action":"seek","value":5,"script":"bad"}}"#
                .utf8)
        let extraCommandField = Data(
            #"{"name":"media.control","mediaRequest":{"targetId":"chrome:7","action":"seek","value":5},"shell":"bad"}"#
                .utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteCommand.self, from: extraRequestField))
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteCommand.self, from: extraCommandField))
    }

    func testActionValuesAreValidatedAndPlayerVolumeUsesAdapterMaximum() throws {
        XCTAssertThrowsError(try MediaRequest(targetID: "tab:8", action: .seek).validate())
        XCTAssertThrowsError(
            try MediaRequest(targetID: "tab:8", action: .playPause, value: 10).validate())
        XCTAssertThrowsError(
            try MediaRequest(targetID: "tab:8", action: .setVolume, value: .infinity).validate())

        let capabilities = MediaCapabilities(
            playPause: true, seek: true, next: false, previous: false,
            playerVolumeMaximum: 2.0)
        XCTAssertTrue(capabilities.supports(.setVolume))
        XCTAssertFalse(capabilities.supports(.next))
        try capabilities.validate()
        XCTAssertThrowsError(
            try MediaCapabilities(
                playPause: false, seek: false, next: false, previous: false,
                playerVolumeMaximum: .nan
            ).validate())
    }

    func testStateRejectsDuplicateMediaTargetIDs() {
        let target = MediaTarget(
            id: "tab:8", name: "YouTube", kind: .youtube,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: false, previous: false))
        let state = RemoteState(
            accessibilityGranted: true, systemVolume: nil, deviceName: "Mac",
            mediaTargets: [target, target])

        XCTAssertThrowsError(try state.validate())
    }

    func testStateRejectsPlayerVolumeWithoutAnAdvertisedMaximum() {
        let target = MediaTarget(
            id: "iina:window-a", name: "IINA", kind: .iina,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: false, previous: false),
            playerVolume: 0)
        let state = RemoteState(
            accessibilityGranted: true, systemVolume: nil, deviceName: "Mac", mediaTargets: [target]
        )
        XCTAssertThrowsError(try state.validate())
    }
}
