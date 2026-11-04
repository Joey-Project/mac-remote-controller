import Foundation

public struct UnlockInstallationRecord: Codable, Sendable {
    public var version = 1
    public var phase = "prepared"
    public var clientUID: UInt32
    public var clientRequirement: String
    public var helperRequirement: String
    public var helperHash: String
    public var pluginHashes: [String: String]
    public var daemonHash: String
    public var originalPolicy: Data
    public var activePolicy: Data?
    public var dedicatedPolicy: Data?
    public var installerDesignatedRequirement = ""
    public var helperDesignatedRequirement = ""

    public static var url: URL { UnlockPaths.directory.appendingPathComponent("receipt.plist") }

    public static func load() throws -> Self {
        let result = try PropertyListDecoder().decode(
            Self.self, from: UnlockFiles.read(url, owner: 0, mode: 0o600))
        guard result.version == 1, result.clientUID > 0, result.clientUID < UInt32.max,
            ["prepared", "installed", "enabling"].contains(result.phase),
            validRequirement(result.clientRequirement, identifier: UnlockPaths.appIdentifier),
            validRequirement(result.helperRequirement, identifier: UnlockPaths.helperIdentifier)
                && !result.installerDesignatedRequirement.isEmpty
                && result.installerDesignatedRequirement.utf8.count <= 1024
                && !result.helperDesignatedRequirement.isEmpty
                && result.helperDesignatedRequirement.utf8.count <= 1024
        else { throw UnlockFailure.setupIncomplete }
        return result
    }

    public func save() throws {
        try UnlockFiles.write(PropertyListEncoder().encode(self), to: Self.url)
        let status = UnlockPublicStatus(
            clientRequirement: clientRequirement, helperRequirement: helperRequirement)
        try UnlockFiles.write(
            PropertyListEncoder().encode(status), to: UnlockPaths.publicStatus, mode: 0o644)
    }

    public static func validRequirement(_ value: String, identifier: String) -> Bool {
        let prefix = "identifier \"\(identifier)\" and cdhash H\""
        guard value.hasPrefix(prefix), value.hasSuffix("\"") else { return false }
        let hash = value.dropFirst(prefix.count).dropLast()
        return hash.count == 40 && hash.allSatisfy({ "0123456789abcdef".contains($0) })
    }
}

public struct UnlockPublicStatus: Codable, Sendable {
    public var clientRequirement: String
    public var helperRequirement: String

    public static func load() throws -> Self {
        let result = try PropertyListDecoder().decode(
            Self.self,
            from: UnlockFiles.read(UnlockPaths.publicStatus, owner: 0, mode: 0o644, maximum: 4096))
        guard
            UnlockInstallationRecord.validRequirement(
                result.clientRequirement, identifier: UnlockPaths.appIdentifier),
            UnlockInstallationRecord.validRequirement(
                result.helperRequirement, identifier: UnlockPaths.helperIdentifier)
        else { throw UnlockFailure.signature }
        return result
    }
}

public struct UnlockSettings: Codable, Sendable {
    public var enabled = false
    public var allowedDeviceIDs: [String] = []
    public init() {}
    public static var url: URL { UnlockPaths.directory.appendingPathComponent("settings.plist") }

    public static func load() throws -> Self {
        let value = try PropertyListDecoder().decode(
            Self.self, from: UnlockFiles.read(url, owner: 0, mode: 0o600))
        guard value.allowedDeviceIDs.count <= 8,
            Set(value.allowedDeviceIDs).count == value.allowedDeviceIDs.count,
            value.allowedDeviceIDs.allSatisfy({ UUID(uuidString: $0) != nil })
        else { throw UnlockFailure.unsafeFile }
        return value
    }

    public func save() throws {
        try UnlockFiles.write(PropertyListEncoder().encode(self), to: Self.url)
    }
}
