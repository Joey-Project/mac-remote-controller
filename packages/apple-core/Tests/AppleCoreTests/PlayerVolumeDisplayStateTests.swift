import AppleCore
import XCTest

final class PlayerVolumeDisplayStateTests: XCTestCase {
    func testRequestedValueSurvivesStaleSnapshotAndRelease() throws {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 200, remoteValue: 40)
        state.request(id: "volume-1", value: 70, wasAccepted: true)
        state.configure(
            targetID: "player-a", maximum: 200, remoteValue: 40, isConnected: true)

        XCTAssertEqual(state.displayedValue, 70)
        state.complete(
            targetID: "player-a", requestID: "volume-1", value: 70, succeeded: true)
        XCTAssertEqual(state.displayedValue, 70)

        state.configure(
            targetID: "player-a", maximum: 200, remoteValue: 40, isConnected: true)
        XCTAssertEqual(state.displayedValue, 70)
        state.configure(
            targetID: "player-a", maximum: 200, remoteValue: 70, isConnected: true)
        XCTAssertEqual(state.displayedValue, 70)
    }

    func testChangedExternalSnapshotOverridesPendingRequests() {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 130, remoteValue: 40)
        state.request(id: "volume-1", value: 70, wasAccepted: true)
        state.configure(
            targetID: "player-a", maximum: 130, remoteValue: 55, isConnected: true)

        XCTAssertEqual(state.displayedValue, 55)
    }

    func testRejectedEnqueueNeverChangesDisplayedValue() {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 130, remoteValue: 40)
        state.request(id: "volume-rejected", value: 70, wasAccepted: false)

        XCTAssertEqual(state.displayedValue, 40)
    }

    func testFailureRollsBackOnlyItsRequestAndPreservesNewerPendingValue() {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 200, remoteValue: 20)
        state.request(id: "volume-1", value: 60, wasAccepted: true)
        state.request(id: "volume-2", value: 80, wasAccepted: true)
        state.complete(
            targetID: "player-a", requestID: "volume-1", value: 60, succeeded: false)

        XCTAssertEqual(state.displayedValue, 80)
        state.complete(
            targetID: "player-a", requestID: "volume-2", value: 80, succeeded: false)
        XCTAssertEqual(state.displayedValue, 20)
    }

    func testSnapshotRetiresPrefixWithoutLettingLateFailureRemoveSameValueRequest() {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 130, remoteValue: 10)
        state.request(id: "volume-old", value: 20, wasAccepted: true)
        state.request(id: "volume-middle", value: 30, wasAccepted: true)
        state.request(id: "volume-new", value: 20, wasAccepted: true)
        state.configure(
            targetID: "player-a", maximum: 130, remoteValue: 20, isConnected: true)
        XCTAssertEqual(state.displayedValue, 20)

        state.complete(
            targetID: "player-a", requestID: "volume-old", value: 20, succeeded: false)
        XCTAssertEqual(state.displayedValue, 20)

        state.complete(
            targetID: "player-a", requestID: "volume-middle", value: 30, succeeded: false)
        XCTAssertEqual(state.displayedValue, 20)
        state.complete(
            targetID: "player-a", requestID: "volume-new", value: 20, succeeded: false)
        XCTAssertEqual(state.displayedValue, 20)
    }

    func testTargetMaximumAndDisconnectResetPendingDisplay() {
        var state = PlayerVolumeDisplayState(targetID: "player-a", maximum: 200, remoteValue: 40)
        state.request(id: "volume-1", value: 150, wasAccepted: true)
        state.configure(
            targetID: "player-a", maximum: 130, remoteValue: 50, isConnected: true)
        XCTAssertEqual(state.displayedValue, 50)

        state.request(id: "volume-2", value: 90, wasAccepted: true)
        state.configure(
            targetID: "player-b", maximum: 130, remoteValue: 60, isConnected: true)
        XCTAssertEqual(state.targetID, "player-b")
        XCTAssertEqual(state.displayedValue, 60)

        state.request(id: "volume-3", value: 80, wasAccepted: true)
        state.configure(
            targetID: nil, maximum: nil, remoteValue: nil, isConnected: false)
        XCTAssertNil(state.displayedValue)
    }

    func testConfirmedValuesPreserveAbsolutePercentageAboveOneHundred() {
        var state = PlayerVolumeDisplayState(targetID: "iina", maximum: 200, remoteValue: 90)
        state.request(id: "volume-1", value: 110, wasAccepted: true)
        state.complete(targetID: "iina", requestID: "volume-1", value: 110, succeeded: true)

        XCTAssertEqual(state.displayedValue, 110)
        state.configure(targetID: "iina", maximum: 200, remoteValue: 90, isConnected: true)
        XCTAssertEqual(state.displayedValue, 110)
        state.configure(targetID: "iina", maximum: 200, remoteValue: 110, isConnected: true)
        XCTAssertEqual(state.displayedValue, 110)
    }
}
