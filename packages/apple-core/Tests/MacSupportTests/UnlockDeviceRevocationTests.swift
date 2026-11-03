import XCTest
@testable import MacSupport

final class UnlockDeviceRevocationTests: XCTestCase {
    func testFailedDenialSurvivesStatusUntilTheHelperConfirmsRemoval() {
        let identifier = UUID().uuidString
        var queue = UnlockDeviceRevocations()
        queue.request(identifier)
        // A busy/unavailable helper supplies no response, so retain the request.
        XCTAssertEqual(queue.next, identifier)
        queue.reconcile(allowed: [identifier], paired: [])
        XCTAssertEqual(queue.next, identifier)
        queue.reconcile(allowed: [], paired: [])
        XCTAssertNil(queue.next)
    }

    func testRestartReconstructsAllEightOrphanedSlotsWithoutRevokingLivePairs() {
        let removed = Set((0..<8).map { _ in UUID().uuidString })
        let live = UUID().uuidString
        var queue = UnlockDeviceRevocations()
        queue.reconcile(allowed: removed, paired: [live])
        XCTAssertEqual(queue.pending, removed)
        for identifier in removed {
            queue.reconcile(allowed: queue.pending.subtracting([identifier]), paired: [live])
        }
        XCTAssertNil(queue.next)
        queue.reconcile(allowed: [live], paired: [live])
        XCTAssertTrue(queue.pending.isEmpty)
    }

    func testExplicitDenialOfStillPairedDeviceRetriesAndCanBeReallowed() {
        let identifier = UUID().uuidString
        var queue = UnlockDeviceRevocations()
        queue.request(identifier)
        queue.reconcile(allowed: [identifier], paired: [identifier])
        XCTAssertEqual(queue.next, identifier)
        queue.cancel(identifier)
        queue.reconcile(allowed: [identifier], paired: [identifier])
        XCTAssertNil(queue.next)
    }

    func testUnknownPairingSnapshotDoesNotRevokeAllowedDevices() {
        let identifier = UUID().uuidString
        var queue = UnlockDeviceRevocations()
        queue.reconcile(allowed: [identifier], paired: nil)
        XCTAssertTrue(queue.pending.isEmpty)
        queue.request(identifier)
        queue.reconcile(allowed: [identifier], paired: nil)
        XCTAssertEqual(queue.next, identifier)
    }

    func testRepeatedReconciliationCoalescesDenialsAcrossReconnects() {
        let identifier = UUID().uuidString
        var queue = UnlockDeviceRevocations()
        for _ in 0..<20 {
            queue.request(identifier)
            queue.reconcile(allowed: [identifier], paired: [])
        }
        XCTAssertEqual(queue.pending, [identifier])
        queue.reconcile(allowed: [], paired: [])
        XCTAssertTrue(queue.pending.isEmpty)
    }
}
