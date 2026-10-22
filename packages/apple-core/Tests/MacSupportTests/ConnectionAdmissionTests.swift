import XCTest
@testable import MacSupport

final class ConnectionAdmissionTests: XCTestCase {
    func testNewPendingConnectionEvictsOldestWhenPoolIsFull() {
        var admission = ConnectionAdmission<Int>(maximumAuthenticated: 3, maximumPending: 3)

        XCTAssertNil(admission.admitPending(1))
        XCTAssertNil(admission.admitPending(2))
        XCTAssertNil(admission.admitPending(3))
        XCTAssertEqual(admission.admitPending(4), 1)

        XCTAssertFalse(admission.remove(1), "A delayed close for an evicted ID must be harmless")
        XCTAssertTrue(admission.authenticate(2))
        XCTAssertTrue(admission.authenticate(3))
        XCTAssertTrue(admission.authenticate(4))
        XCTAssertEqual(admission.pendingCount, 0)
        XCTAssertEqual(admission.authenticatedCount, 3)
    }

    func testAuthenticatedConnectionsAreProtectedFromPendingEviction() {
        var admission = ConnectionAdmission<Int>(maximumAuthenticated: 2, maximumPending: 2)
        XCTAssertNil(admission.admitPending(10))
        XCTAssertTrue(admission.authenticate(10))
        XCTAssertNil(admission.admitPending(11))
        XCTAssertNil(admission.admitPending(12))

        XCTAssertEqual(admission.admitPending(13), 11)
        XCTAssertFalse(admission.remove(11))
        XCTAssertFalse(admission.authenticate(10), "An authenticated ID cannot be promoted twice")
        XCTAssertTrue(admission.authenticate(12))
        XCTAssertFalse(admission.authenticate(13), "The authenticated limit remains enforced")
        XCTAssertEqual(admission.pendingCount, 1)
        XCTAssertEqual(admission.authenticatedCount, 2)
    }

    func testFullAuthenticatedPoolAllowsSameDeviceSessionReplacement() {
        var admission = ConnectionAdmission<Int>(maximumAuthenticated: 8, maximumPending: 4)
        for id in 1...8 {
            XCTAssertNil(admission.admitPending(id))
            XCTAssertTrue(admission.authenticate(id))
        }

        XCTAssertNil(admission.admitPending(9))
        XCTAssertFalse(admission.authenticate(9), "The authenticated limit remains enforced")
        XCTAssertTrue(admission.remove(1), "The replaced session must be removed synchronously")
        XCTAssertTrue(admission.authenticate(9))
        XCTAssertEqual(admission.authenticatedCount, 8)
        XCTAssertEqual(admission.totalCount, 8)
    }

    func testRepeatedIdleReplenishmentKeepsPoolBoundedAndAcceptsEveryNewcomer() {
        var admission = ConnectionAdmission<Int>()
        for id in 0..<1_000 {
            let evicted = admission.admitPending(id)
            if id < admission.maximumPending {
                XCTAssertNil(evicted)
            } else {
                XCTAssertEqual(evicted, id - admission.maximumPending)
            }
            XCTAssertLessThanOrEqual(admission.pendingCount, admission.maximumPending)
            XCTAssertLessThanOrEqual(admission.authenticatedCount, admission.maximumAuthenticated)
            XCTAssertLessThanOrEqual(
                admission.totalCount, admission.maximumAuthenticated + admission.maximumPending)
        }
        XCTAssertEqual(admission.pendingCount, 4)
        XCTAssertEqual(admission.authenticatedCount, 0)
    }
}
