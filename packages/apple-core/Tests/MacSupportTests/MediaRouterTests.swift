import AppleCore
import MacSupport
import XCTest

@MainActor
final class MediaRouterTests: XCTestCase {
    func testExactTargetRoutingAndPlayerMaximum() async throws {
        let router = MediaRouter()
        let selected = MediaTarget(
            id: "iina:window-a", name: "IINA · Episode", kind: .iina,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: false, previous: false,
                playerVolumeMaximum: 1.3))
        try router.update(selected)
        let request = MediaRequest(targetID: selected.id, action: .setVolume, value: 1.25)
        let work = Task {
            try await router.execute(request, requestID: "session-a:1", sessionID: "session-a")
        }
        await Task.yield()
        XCTAssertEqual(router.takeNext(for: .iina)?.targetID, selected.id)
        XCTAssertFalse(router.complete(requestID: "session-a:1", targetID: "iina:other"))
        XCTAssertTrue(router.complete(requestID: "session-a:1", targetID: selected.id))
        try await work.value

        let invalid = MediaRequest(targetID: selected.id, action: .setVolume, value: 1.31)
        do {
            try await router.execute(invalid, requestID: "session-a:2", sessionID: "session-a")
            XCTFail("volume above the adapter's advertised maximum must fail")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testQueueIsBoundedAndSessionCancelDoesNotReplay() async throws {
        let router = MediaRouter(queueLimit: 1)
        let target = MediaTarget(
            id: "chrome:7", name: "YouTube · Test", kind: .youtube,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: true, previous: false))
        try router.update(target)
        let work = Task {
            try await router.execute(
                MediaRequest(targetID: target.id, action: .seek, value: -10),
                requestID: "session-b:1", sessionID: "session-b")
        }
        await Task.yield()
        do {
            try await router.execute(
                MediaRequest(targetID: target.id, action: .next),
                requestID: "session-b:2", sessionID: "session-b")
            XCTFail("full command queue must reject new work")
        } catch {
            XCTAssertEqual(error as? MediaRouteError, .queueFull)
        }
        router.cancel(sessionID: "session-b")
        do {
            try await work.value
            XCTFail("cancelled mobile session must not complete later")
        } catch {
            XCTAssertEqual(error as? MediaRouteError, .cancelled)
        }
        XCTAssertNil(router.takeNext(for: .youtube))
    }

    func testDisconnectedAdapterLeaseRemovesItsTargetsAndQueuedWork() async throws {
        let router = MediaRouter()
        let target = MediaTarget(
            id: "iina:window-c", name: "IINA · Test", kind: .iina,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: false, previous: false))
        let clock = ContinuousClock()
        try router.update(target, at: clock.now.advanced(by: .seconds(-3)))
        let work = Task {
            try await router.execute(
                MediaRequest(targetID: target.id, action: .playPause),
                requestID: "session-c:1", sessionID: "session-c")
        }
        await Task.yield()
        XCTAssertEqual(router.expireStaleTargets(at: clock.now), [target.id])
        XCTAssertNil(router.targets[target.id])
        do {
            try await work.value
            XCTFail("expired target work must not be delivered after it reconnects")
        } catch {
            XCTAssertEqual(error as? MediaRouteError, .targetUnavailable)
        }
        XCTAssertNil(router.takeNext(targetID: target.id))
    }

    func testAdapterTimeoutCompletesBeforeClientDeadlineWithoutReplayingCommand() async throws {
        let router = MediaRouter()
        let target = MediaTarget(
            id: "chrome:timeout", name: "YouTube · Test", kind: .youtube,
            capabilities: MediaCapabilities(
                playPause: true, seek: true, next: true, previous: false))
        try router.update(target)
        let requestID = "session-timeout:1"
        let startedAt = ContinuousClock.now
        let work = Task {
            try await router.execute(
                MediaRequest(targetID: target.id, action: .next),
                requestID: requestID, sessionID: "session-timeout")
        }
        await Task.yield()
        XCTAssertEqual(router.takeNext(for: .youtube)?.requestID, requestID)

        do {
            try await work.value
            XCTFail("an unanswered adapter command must time out")
        } catch {
            XCTAssertEqual(
                error as? MediaRouteError,
                .adapter("The media player did not respond."))
        }

        XCTAssertLessThan(startedAt.duration(to: ContinuousClock.now), .seconds(3))
        XCTAssertNil(router.takeNext(for: .youtube))
    }
}
