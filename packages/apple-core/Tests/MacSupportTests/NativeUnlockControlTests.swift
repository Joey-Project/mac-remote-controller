import ApplicationServices
import XCTest
@testable import MacSupport

final class NativeUnlockControlTests: XCTestCase {
    func testKnownEmptyControlSubmitsWithoutWriting() throws {
        var events: [String] = []
        try NativeUnlockControlPolicy.activate(
            snapshot(), validateContext: { events.append("check") },
            clear: { events.append("clear") }, submit: { events.append("submit") })
        XCTAssertEqual(events, ["check", "submit"])
    }

    func testUnsupportedCountClearsBeforeSubmittingAndRevalidates() throws {
        var events: [String] = []
        try NativeUnlockControlPolicy.activate(
            snapshot(count: nil, status: .attributeUnsupported),
            validateContext: { events.append("check") }, clear: { events.append("clear") },
            submit: { events.append("submit") })
        XCTAssertEqual(events, ["check", "clear", "check", "submit"])
    }

    func testPartiallyEnteredPasswordIsNotSubmittedOrChangedWhenCountIsKnown() {
        var events: [String] = []
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: 3), validateContext: { events.append("check") },
                clear: { events.append("clear") }, submit: { events.append("submit") })
        ) { XCTAssertEqual($0 as? UnlockFailure, .passwordFieldNotEmpty) }
        XCTAssertTrue(events.isEmpty)
    }

    func testOtherReadFailuresAndInvalidCountsNeverClearOrSubmit() {
        for control in [
            snapshot(count: nil, status: .apiDisabled),
            snapshot(count: nil, status: .cannotComplete),
            snapshot(count: nil), snapshot(count: -1)
        ] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    control, validateContext: { events.append("check") },
                    clear: { events.append("clear") }, submit: { events.append("submit") }))
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testOnlyTheIdentifiedSecurePasswordControlCanBeChanged() {
        let valid = snapshot(count: nil, status: .attributeUnsupported)
        var wrongIdentifier = valid
        wrongIdentifier.identifier = "TextInputMenuButton"
        var wrongRole = valid
        wrongRole.role = kAXButtonRole
        var wrongSubrole = valid
        wrongSubrole.subrole = nil
        var disabled = valid
        disabled.enabled = false
        var unfocused = valid
        unfocused.focused = false
        var anotherFocusedControl = valid
        anotherFocusedControl.matchesFocusedElement = false
        for control in [
            wrongIdentifier, wrongRole, wrongSubrole, disabled, unfocused, anotherFocusedControl
        ] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    control, validateContext: { events.append("check") },
                    clear: { events.append("clear") }, submit: { events.append("submit") }))
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testFailedEmptyWriteNeverSubmits() {
        for failure in [UnlockFailure.passwordControlNotWritable, .passwordControlClearFailed] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    snapshot(count: nil, status: .attributeUnsupported),
                    validateContext: { events.append("check") },
                    clear: {
                        events.append("clear"); throw failure
                    },
                    submit: { events.append("submit") })
            ) { XCTAssertEqual($0 as? UnlockFailure, failure) }
            XCTAssertEqual(events, ["check", "clear"])
        }
    }

    func testSessionChangeAfterClearingPreventsSubmission() {
        var events: [String] = []
        var checks = 0
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: nil, status: .attributeUnsupported),
                validateContext: {
                    checks += 1
                    events.append("check")
                    if checks == 2 { throw UnlockFailure.consoleUnavailable }
                }, clear: { events.append("clear") }, submit: { events.append("submit") })
        ) { XCTAssertEqual($0 as? UnlockFailure, .consoleUnavailable) }
        XCTAssertEqual(events, ["check", "clear", "check"])
    }

    func testCancellationBeforeClearingPreventsBothActions() {
        var events: [String] = []
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: nil, status: .attributeUnsupported),
                validateContext: { throw CancellationError() },
                clear: { events.append("clear") }, submit: { events.append("submit") }))
        XCTAssertTrue(events.isEmpty)
    }

    func testSubmissionIsSentOnceForIndependentOSObservation() throws {
        var attempts = 0
        try NativeUnlockControlPolicy.activate(
            snapshot(), validateContext: {}, clear: { XCTFail("Unexpected write") },
            submit: {
                attempts += 1
            })
        XCTAssertEqual(attempts, 1)
    }

    func testSubmissionFailureIsNotRetried() {
        var count = 0
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(), validateContext: {}, clear: { XCTFail("Unexpected write") },
                submit: {
                    count += 1
                    throw UnlockFailure.triggerUnavailable
                }))
        XCTAssertEqual(count, 1)
    }

    func testLostFocusAfterClearingPreventsSubmission() {
        var events: [String] = []
        var checks = 0
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: nil, status: .attributeUnsupported),
                validateContext: {
                    checks += 1
                    if checks == 2 { throw UnlockFailure.passwordControlUnavailable }
                }, clear: { events.append("clear") }, submit: { events.append("submit") })
        ) { XCTAssertEqual($0 as? UnlockFailure, .passwordControlUnavailable) }
        XCTAssertEqual(events, ["clear"])
    }

    func testCancellationBeforeKnownEmptySubmissionDoesNotPost() {
        var submitted = false
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(), validateContext: { throw CancellationError() },
                clear: { XCTFail("Unexpected write") }, submit: { submitted = true }))
        XCTAssertFalse(submitted)
    }

    func testReturnPairUsesOneUnmodifiedNonRepeatingKeyAndItsRelease() throws {
        // Create events only: unit tests never dispatch keyboard input.
        let pair = try XCTUnwrap(NativeUnlockReturnPair())
        XCTAssertEqual(pair.down.type, .keyDown)
        XCTAssertEqual(pair.up.type, .keyUp)
        for event in [pair.down, pair.up] {
            XCTAssertTrue(event.flags.isEmpty)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 36)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventAutorepeat), 0)
        }
    }

    private func snapshot(count: Int? = 0, status: AXError = .success)
        -> NativeUnlockControlSnapshot
    {
        NativeUnlockControlSnapshot(
            identifier: "UserPasswordTextField", role: kAXTextFieldRole,
            subrole: kAXSecureTextFieldSubrole, countStatus: status,
            characterCount: count, enabled: true, focused: true, matchesFocusedElement: true)
    }
}
