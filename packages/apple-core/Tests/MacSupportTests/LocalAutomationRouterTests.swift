import XCTest
@testable import MacSupport

final class LocalAutomationRouterTests: XCTestCase {
    @MainActor
    func testOnlyVisibleEnabledControlsCanExecute() {
        var calls = 0
        for (visible, enabled, unlocked) in [
            (false, true, true), (true, false, true), (true, true, false)
        ] {
            let router = LocalAutomationRouter(
                controls: [.init(.webReload, "Reload", visible: visible, enabled: enabled)],
                values: [:], unlocked: unlocked, readValue: { _ in nil },
                invoke: { _ in calls += 1 })
            let response = router.handle(
                .init(.invoke, control: .webReload), deadline: .now + .seconds(1))
            XCTAssertEqual(response.outcome, .unavailable)
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testToggleRejectsMissingMalformedAndExtraArguments() {
        var calls = 0
        let router = LocalAutomationRouter(
            controls: [.init(.webEnabled, "Web", kind: .toggle)], values: [:], unlocked: true,
            readValue: { _ in nil }, invoke: { _ in calls += 1 })
        for value in [nil, "TRUE", "1", "false; quit"] {
            let response = router.handle(
                .init(.invoke, control: .webEnabled, value: value), deadline: .now + .seconds(1))
            XCTAssertEqual(response.outcome, .invalidRequest)
        }
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .webEnabled, value: "true", path: "/tmp/input"),
                deadline: .now + .seconds(1)
            ).outcome, .invalidRequest)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .webEnabled, value: "true"),
                deadline: .now + .seconds(1)
            ).outcome, .accepted)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testDeviceOperationsRequireAnExactCurrentDevice() {
        let id = UUID().uuidString
        var calls = 0
        let router = LocalAutomationRouter(
            controls: [.init(.deviceRemove, "Remove", deviceID: id)], values: [:], unlocked: true,
            readValue: { _ in nil }, invoke: { _ in calls += 1 })
        for device in [nil, UUID().uuidString] {
            XCTAssertEqual(
                router.handle(
                    .init(.invoke, control: .deviceRemove, deviceID: device),
                    deadline: .now + .seconds(1)
                ).outcome, .invalidRequest)
        }
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .deviceRemove, deviceID: id),
                deadline: .now + .seconds(1)
            ).outcome, .accepted)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testExpiredRequestsNeverExecuteAfterWaitingForMainActor() {
        var calls = 0
        let router = LocalAutomationRouter(
            controls: [.init(.webReload, "Reload")], values: [:], unlocked: true,
            readValue: { _ in nil }, invoke: { _ in calls += 1 })
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .webReload), deadline: .now - .seconds(1)
            ).outcome, .unavailable)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testPairingCodeRequiresExplicitReadAndCannotBeInvokedOrReadWhileLocked() throws {
        var reads = 0
        var calls = 0
        let router = LocalAutomationRouter(
            controls: [.init(.numericCode, "Code", kind: .value)], values: ["state": "ready"],
            unlocked: true,
            readValue: { _ in
                reads += 1; return String(1000 + Int.random(in: 0..<9000))
            },
            invoke: { _ in calls += 1 })
        _ = router.handle(.init(.status), deadline: .now + .seconds(1))
        _ = router.handle(.init(.list), deadline: .now + .seconds(1))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .numericCode),
                deadline: .now + .seconds(1)
            ).outcome, .invalidRequest)
        XCTAssertNotNil(
            router.handle(
                .init(.get, control: .numericCode),
                deadline: .now + .seconds(1)
            ).values?["value"])
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(calls, 0)
        let locked = LocalAutomationRouter(
            controls: router.controls, values: [:], unlocked: false,
            readValue: { _ in
                XCTFail("Locked read reached the code provider"); return nil
            },
            invoke: { _ in XCTFail("Locked action executed") })
        XCTAssertEqual(
            locked.handle(
                .init(.get, control: .numericCode),
                deadline: .now + .seconds(1)
            ).outcome, .unavailable)
    }

    @MainActor
    func testRecoveryAcceptsOnlyAnAbsolutePathAndStatusIsReadOnly() {
        var paths: [String?] = []
        let router = LocalAutomationRouter(
            controls: [.init(.recoveryChooseSetup, "Choose")], values: ["recovery.busy": "false"],
            unlocked: true, readValue: { _ in nil }, invoke: { paths.append($0.path) })
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .recoveryChooseSetup, path: "relative.json"),
                deadline: .now + .seconds(1)
            ).outcome, .invalidRequest)
        XCTAssertEqual(
            router.handle(
                .init(.invoke, control: .recoveryChooseSetup, path: "/tmp/config.json"),
                deadline: .now + .seconds(1)
            ).outcome, .accepted)
        XCTAssertEqual(paths, ["/tmp/config.json"])
        XCTAssertEqual(
            router.handle(.init(.status), deadline: .now + .seconds(1)).values,
            ["recovery.busy": "false"])
        XCTAssertEqual(paths.count, 1)
    }

    func testProtocolRejectsUnknownVersionsOversizedValuesAndInvalidReadArguments() {
        XCTAssertThrowsError(
            try LocalAutomationRequest.decode(
                Data(#"{"version":1,"operation":"status","unexpected":true}"#.utf8)))
        XCTAssertFalse(LocalAutomationRequest(.status, version: 2).isValid)
        XCTAssertFalse(LocalAutomationRequest(.status, control: .appQuit).isValid)
        XCTAssertFalse(LocalAutomationRequest(.get, control: .appQuit, value: "true").isValid)
        XCTAssertFalse(
            LocalAutomationRequest(
                .invoke, control: .webEnabled,
                value: String(repeating: "x", count: 33)
            ).isValid)
        XCTAssertFalse(
            LocalAutomationRequest(
                .invoke, control: .recoveryChooseSetup,
                path: "/tmp/a\0b"
            ).isValid)
    }
}
