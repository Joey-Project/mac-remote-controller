import ApplicationServices
import XCTest
@testable import MacSupport

final class NativeUnlockControlTests: XCTestCase {
    func testKnownEmptyControlConfirmsWithoutWriting() throws {
        var events: [String] = []
        try NativeUnlockControlPolicy.activate(
            snapshot(), validateContext: { events.append("check") },
            clear: { events.append("clear") }, confirm: { events.append("confirm") })
        XCTAssertEqual(events, ["check", "confirm"])
    }

    func testUnsupportedCountClearsBeforeConfirmingAndRevalidates() throws {
        var events: [String] = []
        try NativeUnlockControlPolicy.activate(
            snapshot(count: nil, status: .attributeUnsupported),
            validateContext: { events.append("check") }, clear: { events.append("clear") },
            confirm: { events.append("confirm") })
        XCTAssertEqual(events, ["check", "clear", "check", "confirm"])
    }

    func testPartiallyEnteredPasswordIsNotSubmittedOrChangedWhenCountIsKnown() {
        var events: [String] = []
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: 3), validateContext: { events.append("check") },
                clear: { events.append("clear") }, confirm: { events.append("confirm") })
        ) { XCTAssertEqual($0 as? UnlockFailure, .passwordFieldNotEmpty) }
        XCTAssertTrue(events.isEmpty)
    }

    func testOtherReadFailuresAndInvalidCountsNeverClearOrConfirm() {
        for control in [
            snapshot(count: nil, status: .apiDisabled),
            snapshot(count: nil, status: .cannotComplete),
            snapshot(count: nil), snapshot(count: -1)
        ] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    control, validateContext: { events.append("check") },
                    clear: { events.append("clear") }, confirm: { events.append("confirm") }))
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
        var noConfirm = valid
        noConfirm.supportsConfirm = false
        for control in [wrongIdentifier, wrongRole, wrongSubrole, noConfirm] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    control, validateContext: { events.append("check") },
                    clear: { events.append("clear") }, confirm: { events.append("confirm") }))
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testFailedEmptyWriteNeverConfirms() {
        for failure in [UnlockFailure.passwordControlNotWritable, .passwordControlClearFailed] {
            var events: [String] = []
            XCTAssertThrowsError(
                try NativeUnlockControlPolicy.activate(
                    snapshot(count: nil, status: .attributeUnsupported),
                    validateContext: { events.append("check") },
                    clear: {
                        events.append("clear"); throw failure
                    },
                    confirm: { events.append("confirm") })
            ) { XCTAssertEqual($0 as? UnlockFailure, failure) }
            XCTAssertEqual(events, ["check", "clear"])
        }
    }

    func testSessionChangeAfterClearingPreventsConfirmation() {
        var events: [String] = []
        var checks = 0
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: nil, status: .attributeUnsupported),
                validateContext: {
                    checks += 1
                    events.append("check")
                    if checks == 2 { throw UnlockFailure.consoleUnavailable }
                }, clear: { events.append("clear") }, confirm: { events.append("confirm") })
        ) { XCTAssertEqual($0 as? UnlockFailure, .consoleUnavailable) }
        XCTAssertEqual(events, ["check", "clear", "check"])
    }

    func testCancellationBeforeClearingPreventsBothActions() {
        var events: [String] = []
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(count: nil, status: .attributeUnsupported),
                validateContext: { throw CancellationError() },
                clear: { events.append("clear") }, confirm: { events.append("confirm") }))
        XCTAssertTrue(events.isEmpty)
    }

    func testUncertainConfirmationIsSentOnceForIndependentOSObservation() throws {
        var attempts = 0
        try NativeUnlockControlPolicy.activate(
            snapshot(), validateContext: {}, clear: { XCTFail("Unexpected write") },
            confirm: {
                attempts += 1
                try NativeUnlockControlPolicy.checkConfirmationReply(.cannotComplete)
            })
        XCTAssertEqual(attempts, 1)
    }

    func testConfirmationFailureIsNotRetried() {
        var count = 0
        XCTAssertThrowsError(
            try NativeUnlockControlPolicy.activate(
                snapshot(), validateContext: {}, clear: { XCTFail("Unexpected write") },
                confirm: {
                    count += 1
                    try NativeUnlockControlPolicy.checkConfirmationReply(.actionUnsupported)
                }))
        XCTAssertEqual(count, 1)
    }

    private func snapshot(count: Int? = 0, status: AXError = .success)
        -> NativeUnlockControlSnapshot
    {
        NativeUnlockControlSnapshot(
            identifier: "UserPasswordTextField", role: kAXTextFieldRole,
            subrole: kAXSecureTextFieldSubrole, countStatus: status,
            characterCount: count, supportsConfirm: true)
    }
}
