import Darwin
import Foundation

public enum UnlockDeployment {
    public static func run(arguments: [String]) throws {
        guard geteuid() == 0, arguments.count == 7,
            ["install", "uninstall"].contains(arguments[0]), arguments[1] == "--app",
            arguments[3] == "--uid", arguments[5] == "--client",
            let owner = UInt32(arguments[4]), owner > 0, owner < UInt32.max,
            UnlockInstallationRecord.validRequirement(
                arguments[6], identifier: UnlockPaths.appIdentifier)
        else { throw UnlockFailure.invalidRequest }
        let app = URL(fileURLWithPath: arguments[2])
        let parent = app.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().path == "/private/var/tmp",
            parent.lastPathComponent.hasPrefix("sofaremote-unlock."),
            app.lastPathComponent == "SofaRemoteMac.app"
        else { throw UnlockFailure.unsafeFile }
        try UnlockFiles.ensureDirectory(parent, owner: 0, mode: 0o700)
        try UnlockSigning.verify(app, requirement: arguments[6])
        guard
            try UnlockSigning.requirement(of: app, identifier: UnlockPaths.appIdentifier)
                == arguments[6]
        else {
            throw UnlockFailure.signature
        }
        if arguments[0] == "uninstall" { try uninstall(); return }
        if FileManager.default.fileExists(atPath: UnlockInstallationRecord.url.path) {
            try uninstall()
        }
        try install(app: app, owner: owner, client: arguments[6])
    }

    private static func install(app: URL, owner: UInt32, client: String) throws {
        let helper = app.appendingPathComponent("Contents/Helpers/SofaRemoteUnlockHelper")
        let plugin = app.appendingPathComponent(
            "Contents/Resources/UnlockRuntime/SofaRemoteUnlock.bundle")
        let helperRequirement = try UnlockSigning.requirement(
            of: helper, identifier: UnlockPaths.helperIdentifier)
        let pluginRequirement = try UnlockSigning.requirement(
            of: plugin, identifier: UnlockPaths.pluginIdentifier)
        var helperInfo = stat()
        var pluginInfo = stat()
        guard lstat(helper.path, &helperInfo) == 0, lstat(plugin.path, &pluginInfo) == 0 else {
            throw UnlockFailure.signature
        }
        let helperBytes = try UnlockFiles.read(
            helper, owner: helperInfo.st_uid, maximum: 64 * 1024 * 1024)
        let pluginBytes = try UnlockPluginFiles.snapshot(plugin, owner: pluginInfo.st_uid)
        let daemon = try daemonDefinition()
        try preflightDestinations()
        guard let original = try UnlockAuthorizationDB.read(UnlockPaths.screenRight),
            try UnlockAuthorizationDB.read(UnlockPaths.right) == nil
        else { throw UnlockFailure.conflict }
        _ = try UnlockPolicy.extended(original)
        try UnlockFiles.withStateLock {
            let existing = try FileManager.default.contentsOfDirectory(
                atPath: UnlockPaths.directory.path)
            guard existing.isEmpty else { throw UnlockFailure.setupIncomplete }
            var record = UnlockInstallationRecord(
                clientUID: owner, clientRequirement: client,
                helperRequirement: helperRequirement, helperHash: UnlockFiles.hash(helperBytes),
                pluginHashes: pluginBytes.mapValues(UnlockFiles.hash),
                daemonHash: UnlockFiles.hash(daemon), originalPolicy: original)
            record.installerDesignatedRequirement = try UnlockSigning.designatedRequirement(
                of: app.appendingPathComponent("Contents/Helpers/SofaRemoteUnlockInstaller"))
            record.helperDesignatedRequirement = try UnlockSigning.designatedRequirement(of: helper)
            try record.save()
            try UnlockSettings().save()
            try publishRuntime(
                pluginBytes, requirement: pluginRequirement,
                helperBytes: helperBytes, helperRequirement: helperRequirement, daemon: daemon)
            record.dedicatedPolicy = try UnlockAuthorizationDB.write(
                UnlockPaths.right,
                definition: UnlockPolicy.data(UnlockPolicy.mechanism))
            guard
                try UnlockPolicy.sameDefinition(
                    UnlockAuthorizationDB.read(UnlockPaths.screenRight), original)
            else { throw UnlockFailure.conflict }
            record.phase = "installed"
            try record.save()
        }
        try UnlockSystemCommand.bootstrap()
    }

    private static func publishRuntime(
        _ pluginBytes: [String: Data], requirement: String,
        helperBytes: Data, helperRequirement: String, daemon: Data
    ) throws {
        let staged = UnlockPaths.directory.appendingPathComponent("staged-plugin.bundle")
        try UnlockPluginFiles.stage(pluginBytes, at: staged)
        try UnlockSigning.verify(staged, requirement: requirement)
        guard renamex_np(staged.path, UnlockPaths.plugin.path, UInt32(RENAME_EXCL)) == 0 else {
            throw UnlockFailure.conflict
        }
        try publish(helperBytes, at: UnlockPaths.helper, mode: 0o755)
        try UnlockSigning.verify(UnlockPaths.helper, requirement: helperRequirement)
        try publish(daemon, at: UnlockPaths.daemon, mode: 0o644)
    }

    private static func preflightDestinations() throws {
        for parent in [
            UnlockPaths.plugin.deletingLastPathComponent(),
            UnlockPaths.helper.deletingLastPathComponent(),
            UnlockPaths.daemon.deletingLastPathComponent(),
            UnlockPaths.publicStatus.deletingLastPathComponent()
        ] {
            try UnlockFiles.ensureDirectory(parent, owner: 0, mode: 0o755)
        }
        for path in [
            UnlockPaths.plugin, UnlockPaths.helper, UnlockPaths.daemon, UnlockPaths.publicStatus
        ] {
            var info = stat()
            guard lstat(path.path, &info) != 0, errno == ENOENT else {
                throw UnlockFailure.conflict
            }
        }
    }

    private static func publish(_ data: Data, at destination: URL, mode: mode_t) throws {
        let staged = UnlockPaths.directory.appendingPathComponent(
            "staged-\(destination.lastPathComponent)")
        try UnlockFiles.write(data, to: staged, mode: mode)
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw UnlockFailure.conflict
        }
    }

    private static func daemonDefinition() throws -> Data {
        try UnlockPolicy.data([
            "Label": UnlockPaths.service, "ProgramArguments": [UnlockPaths.helper.path],
            "MachServices": [UnlockPaths.service: true], "RunAtLoad": true,
            "KeepAlive": true, "ThrottleInterval": 10, "Umask": 0o077, "UserName": "root"
        ])
    }

    public static func uninstall() throws {
        try UnlockFiles.withStateLock {
            var record = try UnlockInstallationRecord.load()
            if record.phase == "prepared" {
                try recoverPrepared(record)
                return
            }
            guard ["installed", "enabling"].contains(record.phase),
                let dedicated = record.dedicatedPolicy
            else {
                throw UnlockFailure.setupIncomplete
            }
            let allowed: Set<String> = [
                "receipt.plist", "settings.plist", "lease", "enabled", "grant"
            ]
            let entries = try FileManager.default.contentsOfDirectory(
                atPath: UnlockPaths.directory.path)
            guard Set(entries).isSubset(of: allowed) else { throw UnlockFailure.conflict }
            try UnlockPolicyControl.validateArtifacts(record)
            try UnlockPolicyControl.clearAuthority()
            if let active = record.activePolicy {
                record.originalPolicy = try UnlockPolicyControl.restorePolicy(
                    record: record, active: active)
                record.activePolicy = nil
                record.phase = "installed"
                try record.save()
            } else {
                guard
                    try UnlockPolicy.sameDefinition(
                        UnlockAuthorizationDB.read(UnlockPaths.screenRight), record.originalPolicy)
                else {
                    throw UnlockFailure.conflict
                }
            }
            try UnlockSystemCommand.bootout()
            try removeLeaseIfStopped()
            try UnlockAuthorizationDB.removeDedicated(expected: dedicated)
            try UnlockPluginFiles.remove(UnlockPaths.plugin, expected: record.pluginHashes)
            for path in [
                UnlockPaths.helper, UnlockPaths.daemon, UnlockPaths.publicStatus,
                UnlockSettings.url, UnlockInstallationRecord.url
            ] {
                guard unlink(path.path) == 0 else { throw UnlockFailure.unsafeFile }
            }
            guard rmdir(UnlockPaths.directory.path) == 0,
                try UnlockPolicy.sameDefinition(
                    UnlockAuthorizationDB.read(UnlockPaths.screenRight), record.originalPolicy)
            else {
                throw UnlockFailure.conflict
            }
        }
    }

    static func removeLeaseIfStopped() throws {
        let lease = UnlockPaths.directory.appendingPathComponent("lease")
        var info = stat()
        if lstat(lease.path, &info) != 0 {
            guard errno == ENOENT else { throw UnlockFailure.unsafeFile }
            return
        }
        guard try UnlockFiles.read(lease, owner: 0, mode: 0o600, maximum: 16).count == 16 else {
            throw UnlockFailure.unsafeFile
        }
        let descriptor = open(lease.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw UnlockFailure.unsafeFile }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0, unlink(lease.path) == 0 else {
            throw UnlockFailure.busy
        }
    }
}
