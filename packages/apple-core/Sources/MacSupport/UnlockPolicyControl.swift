import Darwin
import Foundation

public enum UnlockPolicyControl {
    public static func enable() throws {
        try UnlockFiles.withStateLock {
            var record = try UnlockInstallationRecord.load()
            var settings = try UnlockSettings.load()
            guard record.phase == "installed", record.dedicatedPolicy != nil else {
                throw UnlockFailure.notInstalled
            }
            try validateArtifacts(record)
            let current = try UnlockAuthorizationDB.read(UnlockPaths.screenRight)
            if let active = record.activePolicy {
                guard try UnlockPolicy.sameDefinition(current, active) else {
                    throw UnlockFailure.conflict
                }
                if settings.enabled { return }
            } else {
                guard let current, try UnlockPolicy.sameDefinition(current, record.originalPolicy)
                else {
                    throw UnlockFailure.conflict
                }
                let desired = try UnlockPolicy.extended(current)
                record.phase = "enabling"
                record.activePolicy = desired
                try record.save()
                let installed = try UnlockAuthorizationDB.write(
                    UnlockPaths.screenRight, definition: desired)
                record.activePolicy = installed
                record.phase = "installed"
                try record.save()
            }
            settings.enabled = true
            try settings.save()
            try UnlockFiles.write(
                Data("1".utf8), to: UnlockPaths.directory.appendingPathComponent("enabled"))
        }
    }

    public static func disable() throws {
        try UnlockFiles.withStateLock {
            try clearAuthority()
            var record = try UnlockInstallationRecord.load()
            var settings = try UnlockSettings.load()
            settings.enabled = false
            try settings.save()
            if let installed = record.activePolicy {
                record.originalPolicy = try restorePolicy(record: record, active: installed)
                record.activePolicy = nil
                record.phase = "installed"
                try record.save()
            }
        }
    }

    public static func setDevice(_ identifier: String, allowed: Bool) throws {
        guard UUID(uuidString: identifier) != nil else { throw UnlockFailure.invalidRequest }
        try UnlockFiles.withStateLock {
            var settings = try UnlockSettings.load()
            settings.allowedDeviceIDs.removeAll { $0 == identifier }
            if allowed {
                guard settings.allowedDeviceIDs.count < 8 else {
                    throw UnlockFailure.invalidRequest
                }
                settings.allowedDeviceIDs.append(identifier)
            }
            try settings.save()
        }
    }

    public static func validateArtifacts(_ record: UnlockInstallationRecord) throws {
        let status = try UnlockPublicStatus.load()
        _ = try UnlockSettings.load()
        guard
            status.clientRequirement == record.clientRequirement,
            status.helperRequirement == record.helperRequirement,
            try UnlockPluginFiles.snapshot(UnlockPaths.plugin, owner: 0).mapValues(UnlockFiles.hash)
                == record.pluginHashes,
            try UnlockFiles.hash(
                UnlockFiles.read(
                    UnlockPaths.helper, owner: 0, mode: 0o755, maximum: 64 * 1024 * 1024))
                == record.helperHash,
            try UnlockFiles.hash(UnlockFiles.read(UnlockPaths.daemon, owner: 0, mode: 0o644))
                == record.daemonHash,
            try UnlockPolicy.sameDefinition(
                UnlockAuthorizationDB.read(UnlockPaths.right), record.dedicatedPolicy)
        else { throw UnlockFailure.conflict }
    }

    public static func clearAuthority() throws {
        // Called under the shared operation lock, before changing authentication rules.
        for name in ["enabled", "grant"] {
            let url = UnlockPaths.directory.appendingPathComponent(name)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                let bytes = try UnlockFiles.read(url, owner: 0, mode: 0o600, maximum: 144)
                guard
                    name == "enabled"
                        ? bytes == Data("1".utf8)
                        : bytes.count == 144 && bytes.prefix(8) == Data("SRUNL001".utf8)
                else { throw UnlockFailure.conflict }
                guard unlink(url.path) == 0 else { throw UnlockFailure.unsafeFile }
            } else if errno != ENOENT {
                throw UnlockFailure.unsafeFile
            }
        }
    }

    static func restorePolicy(record: UnlockInstallationRecord, active: Data) throws -> Data {
        guard let current = try UnlockAuthorizationDB.read(UnlockPaths.screenRight) else {
            throw UnlockFailure.conflict
        }
        if record.phase == "enabling",
            try UnlockPolicy.sameDefinition(current, record.originalPolicy)
        {
            return current
        }
        guard
            try UnlockPolicy.sameDefinition(current, active)
                || (record.phase == "enabling" && UnlockPolicy.matches(current, desired: active)
                    && UnlockPolicy.createdBy(
                        current, identifier: UnlockPaths.helperIdentifier,
                        requirement: record.helperDesignatedRequirement))
        else {
            throw UnlockFailure.conflict
        }
        return try UnlockAuthorizationDB.write(
            UnlockPaths.screenRight, definition: record.originalPolicy)
    }
}
