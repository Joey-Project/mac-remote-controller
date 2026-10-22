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

    func testExistingIdentityLoadDoesNotEnterCreationOrRollback() throws {
        var rollbackCount = 0

        let material = try ServerIdentity.IdentityLoadTransaction.resolve(
            decision: .loadExisting,
            loadExisting: { ("stored-key", "stored-record") },
            createFresh: {
                try ServerIdentity.IdentityCreationTransaction.perform(
                    createKey: { "new-key" },
                    createRecord: { _ in "new-record" },
                    persistRecord: { _ in },
                    rollbackKey: { _ in rollbackCount += 1 }
                )
            }
        )

        XCTAssertEqual(material.0, "stored-key")
        XCTAssertEqual(material.1, "stored-record")
        XCTAssertEqual(rollbackCount, 0)
    }

    func testRecordCreationFailureRollsBackNewKeyAndPreservesPrimaryError() {
        var rolledBackKeys: [String] = []

        XCTAssertThrowsError(
            try ServerIdentity.IdentityCreationTransaction.perform(
                createKey: { "created-key" },
                createRecord: { _ in throw TestFailure.certificateCreation },
                persistRecord: { _ in XCTFail("Persistence must not run") },
                rollbackKey: { rolledBackKeys.append($0) }
            ) as (String, String)
        ) { error in
            XCTAssertEqual(error as? TestFailure, .certificateCreation)
        }

        XCTAssertEqual(rolledBackKeys, ["created-key"])
    }

    func testPersistenceFailureRollsBackNewKeyAndPreservesPrimaryError() {
        var rolledBackKeys: [String] = []

        XCTAssertThrowsError(
            try ServerIdentity.IdentityCreationTransaction.perform(
                createKey: { "created-key" },
                createRecord: { _ in "certificate-record" },
                persistRecord: { _ in throw TestFailure.persistence },
                rollbackKey: { rolledBackKeys.append($0) }
            ) as (String, String)
        ) { error in
            XCTAssertEqual(error as? TestFailure, .persistence)
        }

        XCTAssertEqual(rolledBackKeys, ["created-key"])
    }

    func testSuccessfulCreationRetainsNewKey() throws {
        var rolledBackKeys: [String] = []

        let material = try ServerIdentity.IdentityCreationTransaction.perform(
            createKey: { "created-key" },
            createRecord: { _ in "certificate-record" },
            persistRecord: { _ in },
            rollbackKey: { rolledBackKeys.append($0) }
        )

        XCTAssertEqual(material.0, "created-key")
        XCTAssertEqual(material.1, "certificate-record")
        XCTAssertTrue(rolledBackKeys.isEmpty)
    }

    func testKeyCreationFailureDoesNotAttemptRollback() {
        var rollbackCount = 0

        XCTAssertThrowsError(
            try ServerIdentity.IdentityCreationTransaction.perform(
                createKey: { throw TestFailure.keyCreation },
                createRecord: { _ in "unused" },
                persistRecord: { _ in },
                rollbackKey: { _ in rollbackCount += 1 }
            ) as (String, String)
        ) { error in
            XCTAssertEqual(error as? TestFailure, .keyCreation)
        }

        XCTAssertEqual(rollbackCount, 0)
    }

    func testRollbackFailurePreservesPrimaryAndCleanupErrors() {
        XCTAssertThrowsError(
            try ServerIdentity.IdentityCreationTransaction.perform(
                createKey: { "created-key" },
                createRecord: { _ in throw TestFailure.certificateCreation },
                persistRecord: { _ in },
                rollbackKey: { _ in throw TestFailure.rollback }
            ) as (String, String)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("certificate creation failed"))
            XCTAssertTrue(error.localizedDescription.contains("key cleanup failed"))
        }
    }
}

private enum TestFailure: Error, LocalizedError, Equatable {
    case keyCreation
    case certificateCreation
    case persistence
    case rollback

    var errorDescription: String? {
        switch self {
        case .keyCreation: "key creation failed"
        case .certificateCreation: "certificate creation failed"
        case .persistence: "record persistence failed"
        case .rollback: "key cleanup failed"
        }
    }
}
