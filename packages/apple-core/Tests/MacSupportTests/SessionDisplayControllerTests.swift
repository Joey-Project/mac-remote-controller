import XCTest
@testable import MacSupport

@MainActor
final class SessionDisplayControllerTests: XCTestCase {
    func testCombinedActionConfirmsLockBeforeHoldingAwakeAndTurningOff() async throws {
        let harness = Harness()
        let controller = harness.controller()
        try await controller.execute(.sessionLockAndDisplayOff)
        XCTAssertEqual(harness.events, ["lock", "hold", "off"])
        XCTAssertTrue(harness.state.locked == true && harness.state.displayAsleep == true)
        controller.endRemoteControl()
        XCTAssertEqual(harness.events.last, "release")
    }

    func testUnconfirmedLockDoesNotTurnOffOrRepeatTheNativeAction() async {
        let harness = Harness()
        harness.lockWorks = false
        do {
            try await harness.controller().execute(.sessionLockAndDisplayOff)
            XCTFail("Expected unconfirmed lock")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .lockUnconfirmed) }
        XCTAssertEqual(harness.events, ["lock"])
        XCTAssertGreaterThanOrEqual(harness.time, 2)
    }

    func testSessionChangeAfterLockNeverTurnsOffTheNewSession() async {
        let harness = Harness()
        harness.changeSessionOnLock = true
        do {
            try await harness.controller().execute(.sessionLockAndDisplayOff)
            XCTFail("Expected session change")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .sessionChanged) }
        XCTAssertEqual(harness.events, ["lock"])
    }

    func testFailedDisplayConfirmationReleasesIdleAssertionAndDoesNotRetry() async {
        let harness = Harness()
        harness.offWorks = false
        do {
            try await harness.controller().execute(.displayOff)
            XCTFail("Expected unconfirmed display")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .displayUnconfirmed) }
        XCTAssertEqual(harness.events, ["hold", "off", "release"])
    }

    func testLockConfirmationCannotUseTheStateOfAChangedSession() async {
        let harness = Harness()
        harness.lockWorks = false
        harness.swapSessionBetweenConfirmationReads = true
        do {
            try await harness.controller().execute(.sessionLock)
            XCTFail("Expected session change instead of accepting another session's lock state")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .sessionChanged) }
        XCTAssertEqual(harness.events, ["lock"])
    }

    func testNativeDisplayFailureReleasesIdleAssertion() async {
        let harness = Harness()
        harness.offThrows = true
        do {
            try await harness.controller().execute(.displayOff)
            XCTFail("Expected native failure")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .unavailable) }
        XCTAssertEqual(harness.events, ["hold", "off", "release"])
    }

    func testRepeatedOffReusesOneAssertionAndWakeReleasesBothAssertions() async throws {
        let harness = Harness()
        let controller = harness.controller()
        try await controller.execute(.displayOff)
        try await controller.execute(.displayOff)
        try await controller.execute(.displayWake)
        XCTAssertEqual(harness.events, ["hold", "off", "wake", "release", "release-wake"])
        XCTAssertEqual(harness.state.locked, false)
        controller.endRemoteControl()
        XCTAssertEqual(harness.events.filter { $0 == "release" }.count, 1)
    }

    func testWakeDoesNotUnlockAndKeepsIdleLeaseWhenTheDisplayStaysAsleep() async throws {
        let harness = Harness()
        let controller = harness.controller()
        harness.state.locked = true
        try await controller.execute(.displayOff)
        harness.wakeWorks = false
        do {
            try await controller.execute(.displayWake)
            XCTFail("Expected unconfirmed wake")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .displayUnconfirmed) }
        XCTAssertEqual(harness.events, ["hold", "off", "wake", "release-wake"])
        XCTAssertEqual(harness.state.locked, true)
        controller.endRemoteControl()
        XCTAssertEqual(harness.events.last, "release")
    }

    func testPhysicalDisplayWakeReleasesAssertionOnExistingStateRefresh() async throws {
        let harness = Harness()
        let controller = harness.controller()
        try await controller.execute(.displayOff)
        XCTAssertEqual(controller.refresh(), true)
        XCTAssertFalse(harness.events.contains("release"))
        harness.state.displayAsleep = false
        XCTAssertEqual(controller.refresh(), false)
        _ = controller.refresh()
        XCTAssertEqual(harness.events.filter { $0 == "release" }.count, 1)
    }

    func testDisconnectReleasesAssertionIdempotently() async throws {
        let harness = Harness()
        let controller = harness.controller()
        try await controller.execute(.displayOff)
        controller.endRemoteControl()
        controller.endRemoteControl()
        XCTAssertEqual(harness.events, ["hold", "off", "release"])
    }

    func testUnknownConsoleOrDisplayNeverInvokesAnAction() async {
        let harness = Harness()
        harness.state.identity = nil
        do {
            try await harness.controller().execute(.sessionLock)
            XCTFail("Expected missing console")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .sessionChanged) }
        harness.state.identity = "session"
        harness.state.displayAsleep = nil
        do {
            try await harness.controller().execute(.displayOff)
            XCTFail("Expected missing display state")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .unavailable) }
        XCTAssertTrue(harness.events.isEmpty)
    }

    func testCancellationDuringConfirmationReleasesIdleAssertion() async {
        let harness = Harness()
        harness.offWorks = false
        harness.cancelPause = true
        do {
            try await harness.controller().execute(.displayOff)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(harness.events, ["hold", "off", "release"])
    }

    func testAlreadyLockedIsIdempotentAndUnavailableSymbolNeverTriggers() async throws {
        let harness = Harness()
        harness.state.locked = true
        let controller = harness.controller(supportsLock: false)
        try await controller.execute(.sessionLock)
        harness.state.locked = false
        do {
            try await controller.execute(.sessionLock)
            XCTFail("Expected unavailable native API")
        } catch { XCTAssertEqual(error as? SessionDisplayFailure, .unavailable) }
        XCTAssertTrue(harness.events.isEmpty)
    }

    func testOverlappingControlIsRejectedWithoutASecondNativeAction() async throws {
        let harness = Harness()
        let controller = harness.controller()
        harness.duringOff = {
            do {
                try await controller.execute(.sessionLock)
                XCTFail("Expected busy controller")
            } catch { XCTAssertEqual(error as? SessionDisplayFailure, .busy) }
        }
        try await controller.execute(.displayOff)
        XCTAssertEqual(harness.events, ["hold", "off"])
        controller.endRemoteControl()
    }
}

@MainActor
private final class Harness {
    var state = SessionDisplaySnapshot(identity: "session", locked: false, displayAsleep: false)
    var time: TimeInterval = 0
    var events: [String] = []
    var lockWorks = true
    var offWorks = true
    var wakeWorks = true
    var offThrows = false
    var changeSessionOnLock = false
    var swapSessionBetweenConfirmationReads = false
    var readsAfterLock = 0
    var cancelPause = false
    var duringOff: (() async -> Void)?

    func controller(supportsLock: Bool = true) -> SessionDisplayController {
        SessionDisplayController(
            operations: .init(
                snapshot: {
                    if self.swapSessionBetweenConfirmationReads && self.events.contains("lock") {
                        self.readsAfterLock += 1
                        if self.readsAfterLock >= 2 {
                            return SessionDisplaySnapshot(
                                identity: "other-session", locked: true, displayAsleep: false)
                        }
                    }
                    return self.state
                },
                lock: {
                    self.events.append("lock")
                    if self.lockWorks { self.state.locked = true }
                    if self.changeSessionOnLock { self.state.identity = "other-session" }
                },
                turnOff: {
                    self.events.append("off")
                    await self.duringOff?()
                    if self.offThrows { throw SessionDisplayFailure.unavailable }
                    if self.offWorks { self.state.displayAsleep = true }
                },
                wake: {
                    self.events.append("wake")
                    if self.wakeWorks { self.state.displayAsleep = false }
                    return { self.events.append("release-wake") }
                },
                preventIdleSleep: {
                    self.events.append("hold")
                    return { self.events.append("release") }
                },
                now: { self.time },
                pause: {
                    if self.cancelPause { throw CancellationError() }
                    self.time += 0.25
                }), supportsLock: supportsLock)
    }
}
