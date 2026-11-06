import XCTest
@testable import MacSupport

final class NativeUnlockPreparationTests: XCTestCase {
    func testWakeWaitsForControlThenSubmitsOnlyOnceAndReleases() async throws {
        let harness = Harness()
        try await NativeUnlockPreparation.run(harness.operations)
        XCTAssertEqual(harness.events, ["wake", "submit", "release"])
        XCTAssertEqual(harness.searches, 3)
    }

    func testReadinessTimeoutReleasesWithoutInput() async {
        let harness = Harness()
        harness.ready = false
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected readiness timeout")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "release"])
        XCTAssertLessThanOrEqual(harness.time, 3)
    }

    func testSessionChangeAfterWakeStopsBeforeFindingOrSubmitting() async {
        let harness = Harness()
        harness.invalidAfterWake = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected session rejection")
        } catch { XCTAssertEqual(error as? UnlockFailure, .consoleUnavailable) }
        XCTAssertEqual(harness.searches, 0)
        XCTAssertEqual(harness.events, ["wake", "release"])
    }

    func testFailedSubmissionIsNotRetriedAndReleasesWakeAssertion() async {
        let harness = Harness()
        harness.submitFailure = .passwordControlClearFailed
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected activation rejection")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlClearFailed) }
        XCTAssertEqual(harness.searches, 3)
        XCTAssertEqual(harness.events, ["wake", "submit", "release"])
    }

    func testInvalidInitialSessionDoesNotWakeTheDisplay() async {
        let harness = Harness()
        harness.invalid = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected invalid session")
        } catch { XCTAssertEqual(error as? UnlockFailure, .consoleUnavailable) }
        XCTAssertTrue(harness.events.isEmpty)
    }

    func testCancellationDuringReadinessReleasesWithoutInput() async {
        let harness = Harness()
        harness.cancelDuringPause = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(harness.events, ["wake", "release"])
    }

    func testSlowDiscoveryCannotSubmitAfterThePreparationDeadline() async {
        let harness = Harness()
        harness.discoveryUsesDeadline = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected preparation timeout")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "release"])
    }

    func testSelectsUserOnceBeforeSubmittingAtThePasswordControl() async throws {
        let harness = Harness()
        harness.requiresSelection = true
        try await NativeUnlockPreparation.run(harness.operations)
        XCTAssertEqual(harness.events, ["wake", "select", "submit", "release"])
        XCTAssertEqual(harness.searches, 3)
    }

    func testRepeatedUserPickerDoesNotRepeatSelectionOrSubmit() async {
        let harness = Harness()
        harness.requiresSelection = true
        harness.selectionRevealsPassword = false
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected missing password control")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "select", "release"])
    }

    func testSelectionFailureIsNotRetriedAndReleasesWakeAssertion() async {
        let harness = Harness()
        harness.requiresSelection = true
        harness.selectionFailure = .passwordControlUnavailable
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected failed native selection")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "select", "release"])
        XCTAssertEqual(harness.searches, 1)
    }

    func testSessionChangeAfterSelectionDoesNotSubmit() async {
        let harness = Harness()
        harness.requiresSelection = true
        harness.invalidAfterSelection = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected changed session rejection")
        } catch { XCTAssertEqual(error as? UnlockFailure, .consoleUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "select", "release"])
    }

    func testLateUserDiscoveryDoesNotSelect() async {
        let harness = Harness()
        harness.requiresSelection = true
        harness.discoveryUsesDeadline = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected preparation timeout")
        } catch { XCTAssertEqual(error as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(harness.events, ["wake", "release"])
    }

    func testCancellationAfterSelectionDoesNotSubmit() async {
        let harness = Harness()
        harness.requiresSelection = true
        harness.cancelDuringPause = true
        do {
            try await NativeUnlockPreparation.run(harness.operations)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(harness.events, ["wake", "select", "release"])
    }
}

private final class Harness {
    var time: TimeInterval = 0
    var events: [String] = []
    var searches = 0
    var ready = true
    var invalid = false
    var invalidAfterWake = false
    var cancelDuringPause = false
    var discoveryUsesDeadline = false
    var requiresSelection = false
    var selectionRevealsPassword = true
    var selectionFailure: UnlockFailure?
    var invalidAfterSelection = false
    var submitFailure: UnlockFailure?

    var operations: NativeUnlockPreparation.Operations<Int> {
        .init(
            now: { self.time },
            validate: {
                if self.invalid || (self.invalidAfterWake && !self.events.isEmpty)
                    || (self.invalidAfterSelection && self.events.contains("select"))
                {
                    throw UnlockFailure.consoleUnavailable
                }
            },
            wake: {
                self.events.append("wake")
                return { self.events.append("release") }
            },
            find: { deadline in
                if self.discoveryUsesDeadline {
                    self.time = deadline
                    return self.requiresSelection ? .userSelection(1) : .password(1)
                }
                self.searches += 1
                if self.requiresSelection
                    && (!self.selectionRevealsPassword || !self.events.contains("select"))
                {
                    return .userSelection(1)
                }
                return self.ready && self.searches >= 3 ? .password(1) : nil
            },
            selectUser: { _, _ in
                self.events.append("select")
                if let failure = self.selectionFailure { throw failure }
            },
            submit: { _, _ in
                self.events.append("submit")
                if let failure = self.submitFailure { throw failure }
            },
            pause: {
                if self.cancelDuringPause { throw CancellationError() }
                self.time += 1
            })
    }
}
