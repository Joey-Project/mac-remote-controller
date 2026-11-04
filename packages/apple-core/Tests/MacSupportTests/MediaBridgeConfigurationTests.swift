import Darwin
import XCTest
@testable import MacSupport

final class MediaBridgeConfigurationTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent(MediaBridgeConfiguration.fileName) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SofaMediaConfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNewConfigurationIsPrivateAndSurvivesReloadWithoutRotation() throws {
        let first = try MediaBridgeConfiguration.loadOrCreate(at: url)
        XCTAssertEqual(first.port, MediaBridgeConfiguration.defaultPort)
        XCTAssertGreaterThanOrEqual(first.token.utf8.count, 32)
        XCTAssertEqual(first, try MediaBridgeConfiguration.loadOrCreate(at: url))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNotEqual(attrs[.protectionKey] as? FileProtectionType, .complete)
    }

    func testUnreadableLegacyProtectionIsBackedUpAndReplacedOnce() throws {
        let original = try MediaBridgeConfiguration.loadOrCreate(at: url)
        let bytes = try Data(contentsOf: url)
        let repaired = try MediaBridgeConfiguration.loadOrCreate(
            at: url, read: { _ in throw POSIXError(.EPERM) },
            attributes: { _ in [.protectionKey: FileProtectionType.complete] })
        XCTAssertNotEqual(repaired.token, original.token)
        XCTAssertEqual(repaired, try MediaBridgeConfiguration.loadOrCreate(at: url))
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasPrefix("media-bridge-protected-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: XCTUnwrap(backups.first).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testCocoaWrappedProtectionFailureCanRecover() throws {
        _ = try MediaBridgeConfiguration.loadOrCreate(at: url)
        let error = NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: POSIXError(.EPERM)])
        _ = try MediaBridgeConfiguration.loadOrCreate(
            at: url, read: { _ in throw error },
            attributes: { _ in [.protectionKey: FileProtectionType.complete] })
        XCTAssertNoThrow(try MediaBridgeConfiguration.loadOrCreate(at: url))
    }

    func testOtherPermissionFailuresDoNotRotateOrMoveExistingConfiguration() throws {
        let original = try MediaBridgeConfiguration.loadOrCreate(at: url)
        for (failure, protection) in [
            (POSIXErrorCode.EACCES, FileProtectionType.complete),
            (.EPERM, .none), (.EIO, .complete)
        ] {
            XCTAssertThrowsError(
                try MediaBridgeConfiguration.loadOrCreate(
                    at: url, read: { _ in throw POSIXError(failure) },
                    attributes: { _ in [.protectionKey: protection] }))
            XCTAssertEqual(try MediaBridgeConfiguration.loadOrCreate(at: url), original)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
    }

    func testMalformedConfigurationIsPreserved() throws {
        let bytes = Data("invalid configuration".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try MediaBridgeConfiguration.loadOrCreate(at: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLinkedConfigurationIsNeverReplacedOrRead() throws {
        let target = directory.appendingPathComponent("external")
        let bytes = Data("untouched".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try MediaBridgeConfiguration.loadOrCreate(at: url))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    }

    func testLinkedConfigurationDirectoryDoesNotReceiveNewCredentials() throws {
        let external = directory.appendingPathComponent("external", isDirectory: true)
        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        XCTAssertThrowsError(
            try MediaBridgeConfiguration.loadOrCreate(
                at: linked.appendingPathComponent("config.json")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }
}
