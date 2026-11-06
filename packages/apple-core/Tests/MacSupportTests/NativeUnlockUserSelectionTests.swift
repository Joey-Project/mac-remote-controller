import ApplicationServices
import XCTest
@testable import MacSupport

final class NativeUnlockUserSelectionTests: XCTestCase {
    private let names = ["Casey Example", "casey"]

    func testSelectsOnlyTheUniqueLoggedInConsoleUser() {
        let buttons = [button("Other User"), button("Casey Example"), button("Guest")]
        XCTAssertEqual(candidate(buttons), 1)
        XCTAssertEqual(candidate([button("casey")]), 0)
    }

    func testRejectsAmbiguousNamesEvenWhenOnlyOneButtonIsActionable() {
        var disabled = button("Casey Example")
        disabled.enabled = false
        XCTAssertNil(candidate([button("Casey Example"), disabled]))
        XCTAssertNil(candidate([button("Casey Example"), button("casey")]))
    }

    func testRejectsOtherUsersPartialNamesAndLoggedOutAccounts() {
        XCTAssertNil(candidate([button("Other User")]))
        XCTAssertNil(candidate([button("Casey")]))
        var loggedOut = button("Casey Example")
        loggedOut.identifier = "User: Casey Example; LoggedIn: logged out"
        XCTAssertNil(candidate([loggedOut]))
        XCTAssertNil(
            NativeUnlockUserSelectionPolicy.candidate(
                in: [button("")], currentNames: [""], collectionReady: true, traversalComplete: true
            ))
    }

    func testIncompleteOrUnfocusedCollectionCannotChooseAUser() {
        let buttons = [button("Casey Example")]
        XCTAssertNil(
            NativeUnlockUserSelectionPolicy.candidate(
                in: buttons, currentNames: names, collectionReady: false, traversalComplete: true))
        XCTAssertNil(
            NativeUnlockUserSelectionPolicy.candidate(
                in: buttons, currentNames: names, collectionReady: true, traversalComplete: false))
        var unreadable = button("Other User")
        unreadable.identifier = nil
        XCTAssertNil(candidate(buttons + [unreadable]))
    }

    func testOnlyNativeActionableUserButtonsAreAccepted() {
        var value = button("Casey Example")
        value.role = kAXStaticTextRole
        XCTAssertNil(candidate([value]))
        value = button("Casey Example")
        value.supportsPress = false
        XCTAssertNil(candidate([value]))
        value = button("Casey Example")
        value.enabled = false
        XCTAssertNil(candidate([value]))
    }

    func testUnsupportedEnabledAttributeIsDistinctFromUnreadableOrMalformed() {
        var value = button("Casey Example")
        value.enabledStatus = .attributeUnsupported
        value.enabled = nil
        XCTAssertEqual(candidate([value]), 0)
        value.enabledStatus = .cannotComplete
        XCTAssertNil(candidate([value]))
        value.enabledStatus = .success
        XCTAssertNil(candidate([value]))
    }

    func testSelectionAcknowledgmentStillRequiresPasswordDiscovery() throws {
        try NativeUnlockUserSelectionPolicy.validateActionResult(.success)
        try NativeUnlockUserSelectionPolicy.validateActionResult(.cannotComplete)
        let failures: [AXError] = [
            .actionUnsupported, .invalidUIElement, .apiDisabled, .illegalArgument
        ]
        for status in failures {
            XCTAssertThrowsError(try NativeUnlockUserSelectionPolicy.validateActionResult(status))
        }
    }

    private func candidate(_ buttons: [NativeUnlockUserButtonSnapshot]) -> Int? {
        NativeUnlockUserSelectionPolicy.candidate(
            in: buttons, currentNames: names, collectionReady: true, traversalComplete: true)
    }

    private func button(_ name: String) -> NativeUnlockUserButtonSnapshot {
        NativeUnlockUserButtonSnapshot(
            identifier: "User: \(name); LoggedIn: logged in", role: kAXButtonRole,
            enabledStatus: .success, enabled: true, supportsPress: true)
    }
}
