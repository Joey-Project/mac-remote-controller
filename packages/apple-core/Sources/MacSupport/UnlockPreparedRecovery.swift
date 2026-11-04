import Darwin
import Foundation

extension UnlockDeployment {
    private struct RecordedFile {
        let url: URL
        let hash: String
        let mode: mode_t
    }

    /// Only remove a recognizable subset of the recorded, disabled publication.
    /// Unknown or partly written staging objects remain for manual diagnosis.
    static func recoverPrepared(_ record: UnlockInstallationRecord) throws {
        guard record.activePolicy == nil,
            try UnlockPolicy.sameDefinition(
                UnlockAuthorizationDB.read(UnlockPaths.screenRight), record.originalPolicy)
        else {
            throw UnlockFailure.conflict
        }
        let stage = UnlockPaths.directory.appendingPathComponent("staged-plugin.bundle")
        let allowed: Set<String> = [
            "receipt.plist", "settings.plist", "staged-plugin.bundle",
            "staged-\(UnlockPaths.helper.lastPathComponent)",
            "staged-\(UnlockPaths.daemon.lastPathComponent)"
        ]
        guard
            Set(try FileManager.default.contentsOfDirectory(atPath: UnlockPaths.directory.path))
                .isSubset(of: allowed)
        else {
            throw UnlockFailure.conflict
        }
        let bundles = try [UnlockPaths.plugin, stage].filter { try exists($0) }
        for bundle in bundles {
            guard
                try UnlockPluginFiles.snapshot(bundle, owner: 0).mapValues(UnlockFiles.hash)
                    == record.pluginHashes
            else {
                throw UnlockFailure.conflict
            }
        }
        let present = try preparedFiles(record)
        let privateFiles = try preparedPrivateFiles(record)
        let dedicated = try preparedDedicatedRight(record)
        // Every candidate is admitted before the first mutation.
        if let dedicated { try UnlockAuthorizationDB.removeDedicated(expected: dedicated) }
        for bundle in bundles {
            try UnlockPluginFiles.remove(bundle, expected: record.pluginHashes)
        }
        for url in present + privateFiles {
            guard unlink(url.path) == 0 else { throw UnlockFailure.unsafeFile }
        }
        guard
            try UnlockPolicy.sameDefinition(
                UnlockAuthorizationDB.read(UnlockPaths.screenRight), record.originalPolicy),
            unlink(UnlockInstallationRecord.url.path) == 0, rmdir(UnlockPaths.directory.path) == 0
        else {
            throw UnlockFailure.conflict
        }
    }

    private static func preparedFiles(_ record: UnlockInstallationRecord) throws -> [URL] {
        let published = [
            RecordedFile(url: UnlockPaths.helper, hash: record.helperHash, mode: 0o755),
            RecordedFile(url: UnlockPaths.daemon, hash: record.daemonHash, mode: 0o644)
        ]
        let staged = published.map {
            RecordedFile(
                url: UnlockPaths.directory.appendingPathComponent(
                    "staged-\($0.url.lastPathComponent)"),
                hash: $0.hash, mode: $0.mode)
        }
        let present = try (published + staged).filter { try exists($0.url) }
        for file in present {
            guard
                try UnlockFiles.hash(
                    UnlockFiles.read(
                        file.url, owner: 0, mode: file.mode,
                        maximum: 64 * 1024 * 1024)) == file.hash
            else { throw UnlockFailure.conflict }
        }
        return present.map(\.url)
    }

    private static func preparedPrivateFiles(_ record: UnlockInstallationRecord) throws -> [URL] {
        if try exists(UnlockPaths.publicStatus) {
            let status = try UnlockPublicStatus.load()
            guard status.clientRequirement == record.clientRequirement,
                status.helperRequirement == record.helperRequirement
            else {
                throw UnlockFailure.conflict
            }
        }
        let files = try [UnlockSettings.url, UnlockPaths.publicStatus].filter { try exists($0) }
        for url in files {
            _ = try UnlockFiles.read(
                url, owner: 0, mode: url == UnlockPaths.publicStatus ? 0o644 : 0o600,
                maximum: 16_384)
        }
        return files
    }

    private static func preparedDedicatedRight(_ record: UnlockInstallationRecord) throws -> Data? {
        let dedicated = try UnlockAuthorizationDB.read(UnlockPaths.right)
        if let dedicated {
            let values = try UnlockPolicy.dictionary(dedicated)
            guard
                try UnlockPolicy.matches(
                    dedicated, desired: UnlockPolicy.data(UnlockPolicy.mechanism)),
                values["identifier"] as? String == UnlockPaths.installerIdentifier,
                values["requirement"] as? String == record.installerDesignatedRequirement
            else {
                throw UnlockFailure.conflict
            }
        }
        return dedicated
    }

    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw UnlockFailure.unsafeFile }
        return false
    }
}
