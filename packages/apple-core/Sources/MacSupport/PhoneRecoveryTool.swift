import Darwin
import Foundation

public struct PhoneRecoveryConfiguration: Codable, Sendable {
    public var probeApp: String
    public var iosApp: String
    public var deviceIdentifier: String
    public var deviceUDID: String
    public var runDirectory: String

    public static func load(_ url: URL) throws -> Self {
        let bytes = try UnlockFiles.read(url, owner: getuid(), mode: 0o600, maximum: 16_384)
        guard let raw = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
            Set(raw.keys) == [
                "probeApp", "iosApp", "deviceIdentifier", "deviceUDID", "runDirectory"
            ],
            raw.values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 4096 })
        else { throw UnlockFailure.invalidRequest }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard [value.probeApp, value.iosApp, value.runDirectory].allSatisfy({ $0.hasPrefix("/") })
        else {
            throw UnlockFailure.invalidRequest
        }
        return value
    }

    public func save(_ url: URL) throws {
        try UnlockFiles.write(JSONEncoder().encode(self), to: url)
    }
}

public struct PhoneRecoveryReceipt: Decodable, Sendable {
    public let status: String
    public let candidatePath: String?
    public let expiration: String?
    public let installedAppReadback: Bool?
    public let category: String?
}

public enum PhoneRecoveryTool {
    public static func configure(from source: URL, directory: URL) throws -> URL {
        var config = try PhoneRecoveryConfiguration.load(source)
        try preparePrivateDirectory(directory)
        let reference = URL(fileURLWithPath: config.iosApp)
        let requirement = try UnlockSigning.requirement(
            of: reference, identifier: "com.joeyteng.sofaremote.ios")
        let saved = directory.appendingPathComponent("Accepted-\(UUID().uuidString).app")
        try FileManager.default.copyItem(at: reference, to: saved)
        try UnlockSigning.verify(saved, requirement: requirement)
        config.iosApp = saved.path
        config.runDirectory = directory.appendingPathComponent("Runs").path
        let destination = directory.appendingPathComponent("configuration-private.json")
        try config.save(destination)
        return destination
    }

    public static func run(configuration: URL, runner: URL) throws -> PhoneRecoveryReceipt {
        let config = try PhoneRecoveryConfiguration.load(configuration)
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"
        ]
        let python = try pythonExecutable(environment: environment)
        let bytes = try UnlockFiles.read(
            configuration, owner: getuid(), mode: 0o600, maximum: 16_384)
        let job = configuration.deletingLastPathComponent().appendingPathComponent(
            "Manual-\(UUID().uuidString)")
        try UnlockFiles.ensureDirectory(job, owner: getuid(), mode: 0o700)
        let snapshot = job.appendingPathComponent("configuration-private.json")
        try config.save(snapshot)
        let result = try UnlockSystemCommand.run(
            python,
            arguments: [
                "-I", runner.path, "ios-install", "--manual-recovery", "--config", snapshot.path
            ],
            seconds: 360, maximumBytes: 32_768, environment: environment)
        let receipt = try JSONDecoder().decode(PhoneRecoveryReceipt.self, from: result.output)
        guard result.status == 0, receipt.status == "passed", receipt.installedAppReadback == true,
            let candidate = receipt.candidatePath, candidate.hasPrefix(config.runDirectory + "/")
        else {
            throw PhoneRecoveryError.failed(receipt.category)
        }
        guard
            try UnlockFiles.read(configuration, owner: getuid(), mode: 0o600, maximum: 16_384)
                == bytes
        else {
            throw PhoneRecoveryError.configurationChanged
        }
        var next = config
        next.iosApp = candidate
        try next.save(configuration)
        return receipt
    }

    private static func pythonExecutable(environment: [String: String]) throws -> String {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let check = try UnlockSystemCommand.run(
                path,
                arguments: [
                    "-I", "-c", "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)"
                ],
                seconds: 5, maximumBytes: 4096, environment: environment)
            if check.status == 0 { return path }
        }
        throw PhoneRecoveryError.pythonRequired
    }

    private static func preparePrivateDirectory(_ directory: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var current = directory
        while current.path != home.path, current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR {
                throw UnlockFailure.unsafeFile
            }
            current.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try UnlockFiles.ensureDirectory(directory, owner: getuid(), mode: 0o700)
    }
}

public enum PhoneRecoveryError: Error, LocalizedError, Sendable {
    case pythonRequired, configurationChanged, failed(String?)
    public var errorDescription: String? {
        switch self {
        case .pythonRequired: "Phone recovery needs Python 3.11 or newer on this Mac."
        case .configurationChanged:
            "The app was installed, but recovery setup changed during the run. Select the setup again."
        case .failed(let category):
            switch category {
            case "mac-probe-expired-bootstrap-required":
                "The Mac renewal tool has expired. Repair its signing in Xcode first."
            case "issue-profile-timeout", "validation-or-command-failed":
                "Recovery could not finish. Check the paired phone connection and saved Apple account session."
            default:
                "Phone recovery was not confirmed. Check the renewal setup and phone connection."
            }
        }
    }
}
