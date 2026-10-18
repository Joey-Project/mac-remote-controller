import XCTest
@testable import MacSupport

final class ServerIdentityTests: XCTestCase {
    func testEmptyStorageAllowsFirstRunCreation() {
        XCTAssertEqual(
            ServerIdentity.IdentityLoadDecision.resolve(
                hasStoredRecord: false,
                hasPrivateKey: false
            ),
            .createFresh
        )
    }

    func testStoredRecordAndKeyLoadExistingIdentity() {
        XCTAssertEqual(
            ServerIdentity.IdentityLoadDecision.resolve(
                hasStoredRecord: true,
                hasPrivateKey: true
            ),
            .loadExisting
        )
    }

    func testOrphanedPersistentKeyFailsClosed() {
        XCTAssertEqual(
            ServerIdentity.IdentityLoadDecision.resolve(
                hasStoredRecord: false,
                hasPrivateKey: true
            ),
            .orphanedPrivateKey
        )
    }

    func testStoredRecordWithoutKeyRetainsMissingKeyFailure() {
        XCTAssertEqual(
            ServerIdentity.IdentityLoadDecision.resolve(
                hasStoredRecord: true,
                hasPrivateKey: false
            ),
            .missingPrivateKey
        )
    }
}
