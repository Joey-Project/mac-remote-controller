import Darwin
import Foundation
import Security

public struct MediaBridgeConfiguration: Codable, Sendable, Equatable {
    public let port: UInt16
    public let token: String

    public static let defaultPort: UInt16 = 47_623
    public static let fileName = "media-bridge.json"

    public static var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SofaRemote", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func loadOrCreate() throws -> Self { try loadOrCreate(at: configurationURL) }

    static func loadOrCreate(
        at url: URL,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) },
        attributes: (URL) throws -> [FileAttributeKey: Any] = {
            try FileManager.default.attributesOfItem(atPath: $0.path)
        }
    ) throws -> Self {
        let files = FileManager.default
        try validateDirectory(url.deletingLastPathComponent())
        var original: stat?
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                throw MediaBridgeError.invalidConfiguration
            }
            do {
                let value = try JSONDecoder().decode(Self.self, from: read(url))
                guard value.port > 0, value.token.utf8.count >= 32 else {
                    throw MediaBridgeError.invalidConfiguration
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return value
            } catch {
                // Only recover the specific legacy Data Protection failure. Keep corrupt,
                // foreign-owned and ordinary permission-denied files for explicit diagnosis.
                guard isProtectionFailure(error),
                    try attributes(url)[.protectionKey] as? FileProtectionType == .complete,
                    info.st_mode & 0o7777 == 0o600
                else { throw error }
                original = info
            }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let value = try fresh()
        try write(value, to: url, preserving: original)
        return value
    }

    private static func isProtectionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(EPERM) }
        guard error.domain == NSCocoaErrorDomain,
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EPERM)
    }

    private static func fresh() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MediaBridgeError.randomUnavailable
        }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Self(port: defaultPort, token: token)
    }

    private static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
            info.st_mode & 0o022 == 0
        else { throw MediaBridgeError.invalidConfiguration }
    }

    private static func write(_ value: Self, to url: URL, preserving original: stat?) throws {
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try validateDirectory(directory)
        let staging = directory.appendingPathComponent(".media-bridge-\(UUID().uuidString)")
        let descriptor = open(
            staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? files.removeItem(at: staging) }
        // Shared by the companion and Chrome's separately signed native host, including
        // while locked. Use owner-only POSIX access rather than complete file protection.
        try handle.write(contentsOf: JSONEncoder().encode(value))
        try handle.synchronize()
        if let original {
            var current = stat()
            // Preserve the admitted object and its owner-only access policy. Directory
            // entry churn and timestamps are not evidence that this file was replaced.
            guard lstat(url.path, &current) == 0,
                current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                current.st_uid == original.st_uid, current.st_mode == original.st_mode
            else { throw MediaBridgeError.invalidConfiguration }
            let backup = directory.appendingPathComponent(
                "media-bridge-protected-\(UUID().uuidString).json")
            try files.moveItem(at: url, to: backup)
            do { try files.moveItem(at: staging, to: url) } catch {
                try? files.moveItem(at: backup, to: url); throw error
            }
        } else {
            // Do not overwrite another process's freshly created configuration.
            try files.moveItem(at: staging, to: url)
        }
    }
}
