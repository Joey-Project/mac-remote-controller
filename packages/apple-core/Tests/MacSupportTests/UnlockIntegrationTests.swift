import Darwin
import Foundation
import Security
import XCTest
@testable import MacSupport

final class UnlockIntegrationTests: XCTestCase {
    func testCompanionAdmissionRequiresRuntimeAndRejectsInjectionEntitlements() throws {
        let flags = kSecCodeInfoFlags as String
        let entitlements = kSecCodeInfoEntitlementsDict as String
        let valid: [String: Any] = [flags: NSNumber(value: SecCodeSignatureFlags.runtime.rawValue)]
        try UnlockSigning.admitCompanion(valid)
        XCTAssertThrowsError(try UnlockSigning.admitCompanion([flags: 0]))
        for key in [
            "com.apple.security.get-task-allow", "get-task-allow",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.disable-executable-page-protection",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory"
        ] {
            var changed = valid
            changed[entitlements] = [key: true]
            XCTAssertThrowsError(try UnlockSigning.admitCompanion(changed))
            changed[entitlements] = [key: "unexpected-type"]
            XCTAssertThrowsError(try UnlockSigning.admitCompanion(changed))
        }
    }

    func testPolicyPreservesExistingVendorAndPasswordBranchesInOrder() throws {
        let original: [String: Any] = [
            "class": "rule", "k-of-n": 1,
            "rule": ["existing.vendor.unlock", "use-login-window-ui"], "comment": "keep"
        ]
        let extended = try UnlockPolicy.dictionary(
            UnlockPolicy.extended(UnlockPolicy.data(original)))
        XCTAssertEqual(
            extended["rule"] as? [String],
            [UnlockPaths.right, "existing.vendor.unlock", "use-login-window-ui"])
        XCTAssertEqual(extended["comment"] as? String, "keep")
        XCTAssertEqual(
            original["rule"] as? [String], ["existing.vendor.unlock", "use-login-window-ui"])
    }

    func testUnsupportedCompositionAndDuplicateBranchAreRefused() throws {
        for values: [String: Any] in [
            ["class": "rule", "k-of-n": 0, "rule": ["password", "second-factor"]],
            ["class": "rule", "k-of-n": true, "rule": ["password"]],
            ["class": "rule", "k-of-n": 1.5, "rule": ["password"]],
            ["class": "rule", "k-of-n": 1, "rule": [UnlockPaths.right, "password"]],
            ["class": "allow"], ["class": "rule", "k-of-n": 1, "rule": []]
        ] {
            XCTAssertThrowsError(try UnlockPolicy.extended(UnlockPolicy.data(values)))
        }
    }

    func testInterruptedWriteRecoveryRequiresTheRecordedCreator() throws {
        let values: [String: Any] = [
            "class": "rule", "k-of-n": 1, "rule": [UnlockPaths.right, "password"],
            "identifier": UnlockPaths.helperIdentifier, "requirement": "recorded creator",
            "modified": 10
        ]
        let bytes = try UnlockPolicy.data(values)
        XCTAssertTrue(
            try UnlockPolicy.createdBy(
                bytes, identifier: UnlockPaths.helperIdentifier, requirement: "recorded creator"))
        XCTAssertFalse(
            try UnlockPolicy.createdBy(
                bytes, identifier: UnlockPaths.helperIdentifier, requirement: "foreign creator"))
        let definition = try UnlockPolicy.writeDefinition(bytes)
        XCTAssertNil(definition["identifier"])
        XCTAssertNil(definition["requirement"])
        XCTAssertNil(definition["modified"])
        XCTAssertEqual(definition["rule"] as? [String], [UnlockPaths.right, "password"])
    }

    func testFreshnessIncludesModificationAndOwnerMetadataButNotEncoding() throws {
        let values: [String: Any] = [
            "class": "rule", "k-of-n": 1, "rule": ["password"],
            "modified": 123.25, "identifier": "original.owner"
        ]
        let xml = try UnlockPolicy.data(values)
        let binary = try PropertyListSerialization.data(
            fromPropertyList: values, format: .binary, options: 0)
        XCTAssertTrue(try UnlockPolicy.sameDefinition(xml, binary))
        for changed in [["modified": 124.0], ["identifier": "new.owner"], ["rule": ["allow"]]]
            as [[String: Any]]
        {
            XCTAssertFalse(
                try UnlockPolicy.sameDefinition(
                    xml, UnlockPolicy.data(values.merging(changed) { _, new in new })))
        }
    }

    func testPostWriteNormalizationDoesNotHideBehaviorChanges() throws {
        let expected = try UnlockPolicy.data(UnlockPolicy.mechanism)
        var returned = UnlockPolicy.mechanism
        returned["created"] = 1.0
        returned["modified"] = 2.0
        returned["identifier"] = UnlockPaths.helperIdentifier
        returned["requirement"] = "creator metadata"
        XCTAssertTrue(try UnlockPolicy.matches(UnlockPolicy.data(returned), desired: expected))
        returned["mechanisms"] = ["other:allow,privileged"]
        XCTAssertFalse(try UnlockPolicy.matches(UnlockPolicy.data(returned), desired: expected))
    }

    func testRequestsHaveNoArbitraryPathCommandOrAccountFields() throws {
        try UnlockRequest(.status).validate()
        try UnlockRequest(.begin, deviceID: UUID().uuidString).validate()
        try UnlockRequest(.wait, transactionID: UUID().uuidString).validate()
        for request in [
            UnlockRequest(.begin), UnlockRequest(.status, deviceID: UUID().uuidString),
            UnlockRequest(.wait, transactionID: "not-an-id"),
            UnlockRequest(.cancel, deviceID: UUID().uuidString, transactionID: UUID().uuidString)
        ] {
            XCTAssertThrowsError(try request.validate())
        }
    }

    func testCodeRequirementsAreBoundToExactIdentifierAndHash() {
        let requirement =
            "identifier \"\(UnlockPaths.appIdentifier)\" and cdhash H\"0123456789abcdef0123456789abcdef01234567\""
        XCTAssertTrue(
            UnlockInstallationRecord.validRequirement(
                requirement, identifier: UnlockPaths.appIdentifier))
        for invalid in [
            "true", requirement + " or true",
            requirement.replacingOccurrences(of: "cdhash", with: "identifier"),
            requirement.replacingOccurrences(of: "01234567", with: "zzzzzzzz")
        ] {
            XCTAssertFalse(
                UnlockInstallationRecord.validRequirement(
                    invalid, identifier: UnlockPaths.appIdentifier))
        }
        XCTAssertFalse(
            UnlockInstallationRecord.validRequirement(
                requirement, identifier: UnlockPaths.helperIdentifier))
    }

    func testSetupQuotesPathsAndVerifiesBeforeInstallerExecution() throws {
        let requirement =
            "identifier \"\(UnlockPaths.appIdentifier)\" and cdhash H\"0123456789abcdef0123456789abcdef01234567\""
        let script = try UnlockSetupCommand.script(
            app: URL(fileURLWithPath: "/Users/O'Brien/Applications/SofaRemoteMac.app"),
            clientRequirement: requirement, uid: 501, uninstall: false)
        XCTAssertTrue(script.contains("O'\\''Brien"))
        let verify = try XCTUnwrap(script.range(of: "/usr/bin/codesign --verify --deep --strict"))
        let execute = try XCTUnwrap(script.range(of: "Contents/Helpers/SofaRemoteUnlockInstaller"))
        XCTAssertLessThan(verify.lowerBound, execute.lowerBound)
        XCTAssertTrue(
            script.contains("/usr/bin/mktemp -d /private/var/tmp/sofaremote-unlock.XXXXXXXX"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaSetup-\(UUID().uuidString).sh")
        try UnlockFiles.write(Data(script.utf8), to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            try UnlockSystemCommand.run("/bin/bash", arguments: ["-n", file.path], seconds: 3)
                .status, 0)
    }

    func testFixedCommandRunnerHandlesExitAndEnforcesItsDeadline() throws {
        XCTAssertEqual(
            try UnlockSystemCommand.run("/usr/bin/true", arguments: [], seconds: 2).status, 0)
        XCTAssertEqual(
            try UnlockSystemCommand.run("/usr/bin/false", arguments: [], seconds: 2).status, 1)
        XCTAssertThrowsError(
            try UnlockSystemCommand.run("/bin/sleep", arguments: ["5"], seconds: 0.1)
        ) {
            XCTAssertEqual($0 as? UnlockFailure, .timedOut)
        }
    }

    func testPublicationAppliesItsRecordedModesUnderPrivateInstallerUmask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaModes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalMask = umask(0o077)
        defer { umask(originalMask) }
        let child = root.appendingPathComponent("new-directory")
        try UnlockFiles.ensureDirectory(child, owner: getuid(), mode: 0o755)
        var info = stat()
        XCTAssertEqual(lstat(child.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o755)
        let path = child.appendingPathComponent("helper")
        try UnlockFiles.write(Data("fixture".utf8), to: path, mode: 0o755)
        XCTAssertEqual(
            try UnlockFiles.read(path, owner: getuid(), mode: 0o755), Data("fixture".utf8))
        XCTAssertEqual(chmod(child.path, 0o700), 0)
        XCTAssertThrowsError(try UnlockFiles.ensureDirectory(child, owner: getuid(), mode: 0o755))
        XCTAssertEqual(lstat(child.path, &info), 0)
        XCTAssertEqual(
            info.st_mode & 0o7777, 0o700, "An existing access policy must not be changed.")
    }

    func testSharedHelperParentAcceptsStickyBitWithoutChangingItsAccessPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaStickyParent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode: mode_t in [0o755, 0o1755] {
            XCTAssertEqual(chmod(root.path, mode), 0)
            var before = stat()
            XCTAssertEqual(lstat(root.path, &before), 0)
            try UnlockFiles.ensureDirectory(
                root, owner: getuid(), mode: 0o755, allowStickyBit: true)
            var after = stat()
            XCTAssertEqual(lstat(root.path, &after), 0)
            XCTAssertEqual(after.st_dev, before.st_dev)
            XCTAssertEqual(after.st_ino, before.st_ino)
            XCTAssertEqual(after.st_uid, before.st_uid)
            XCTAssertEqual(after.st_mode, before.st_mode)
        }
        XCTAssertThrowsError(try UnlockFiles.ensureDirectory(root, owner: getuid(), mode: 0o755))
        XCTAssertThrowsError(
            try UnlockFiles.ensureDirectory(
                root, owner: getuid() + 1, mode: 0o755, allowStickyBit: true))
        let alias = root.deletingLastPathComponent().appendingPathComponent(
            "SofaStickyLink-\(UUID().uuidString)")
        XCTAssertEqual(symlink(root.path, alias.path), 0)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(
            try UnlockFiles.ensureDirectory(
                alias, owner: getuid(), mode: 0o755, allowStickyBit: true))
    }

    func testSharedHelperParentStillRejectsWriteAccessAndOtherSpecialBits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaUnsafeParent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode: mode_t in [0o775, 0o777, 0o1777, 0o2755, 0o4755, 0o700] {
            XCTAssertEqual(chmod(root.path, mode), 0)
            XCTAssertThrowsError(
                try UnlockFiles.ensureDirectory(
                    root, owner: getuid(), mode: 0o755, allowStickyBit: true))
            var info = stat()
            XCTAssertEqual(lstat(root.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o7777, mode)
        }
    }

    func testPrivateRecoveryConfigRejectsCredentialFieldsLinksAndBroadMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SofaRecoveryTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        let values = [
            "probeApp": "/tmp/Probe.app", "iosApp": "/tmp/iOS.app", "deviceIdentifier": "device",
            "deviceUDID": "udid", "runDirectory": "/tmp/runs"
        ]
        try UnlockFiles.write(JSONEncoder().encode(values), to: path)
        XCTAssertEqual(try PhoneRecoveryConfiguration.load(path).iosApp, "/tmp/iOS.app")
        try UnlockFiles.write(
            JSONEncoder().encode(values.merging(["password": "not-accepted"]) { _, new in new }),
            to: path)
        XCTAssertThrowsError(try PhoneRecoveryConfiguration.load(path))
        try UnlockFiles.write(JSONEncoder().encode(values), to: path)
        XCTAssertEqual(chmod(path.path, 0o644), 0)
        XCTAssertThrowsError(try PhoneRecoveryConfiguration.load(path))
        XCTAssertEqual(chmod(path.path, 0o600), 0)
        let alias = directory.appendingPathComponent("link.json")
        XCTAssertEqual(symlink(path.path, alias.path), 0)
        XCTAssertThrowsError(try PhoneRecoveryConfiguration.load(alias))
    }
}
