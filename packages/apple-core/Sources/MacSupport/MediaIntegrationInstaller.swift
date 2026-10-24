import Darwin
import Foundation

/// Installs only Sofa Remote's own integration files under the current user's Library.
public struct MediaIntegrationInstaller {
    public static let extensionID = "bjplbbniljmmhclleegdfdonjmjlpnid"
    public static let pluginID = "com.joeyteng.sofaremote.iina"
    public static let nativeHostName = "com.joeyteng.sofaremote"

    let home: URL
    let resources: URL
    let helper: URL
    let files = FileManager.default

    public init(home: URL, resources: URL, helper: URL) {
        self.home = home
        self.resources = resources
        self.helper = helper
    }

    public func installIINA(configuration: MediaBridgeConfiguration) throws -> URL {
        let source = resources.appendingPathComponent("SofaRemote.iinaplugin")
        let pluginRoot = applicationSupport.appendingPathComponent("com.colliderli.iina/plugins")
        let destination = pluginRoot.appendingPathComponent(Self.pluginID + ".iinaplugin")
        let preferences = pluginRoot.appendingPathComponent(".preferences")
            .appendingPathComponent(Self.pluginID + ".plist")
        try requireRegularFile(source.appendingPathComponent("Info.json"))
        try requireRegularFile(source.appendingPathComponent("main.js"))
        try ensureDirectory(preferences.deletingLastPathComponent())
        try rejectLink(preferences)
        var values: [String: Any] = [:]
        if files.fileExists(atPath: preferences.path) {
            try requireRegularFile(preferences)
            guard
                let existing = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: preferences), format: nil) as? [String: Any]
            else { throw IntegrationSetupError.invalidPreferences }
            values = existing
        }
        values["bridge_port"] = Int(configuration.port)
        values["bridge_token"] = configuration.token
        let data = try PropertyListSerialization.data(
            fromPropertyList: values, format: .binary, options: 0)
        try installDirectory(source, at: destination)
        try writePrivate(data, to: preferences)
        return destination
    }

    public func installChrome() throws -> URL {
        let source = resources.appendingPathComponent("ChromeExtension")
        try requireRegularFile(source.appendingPathComponent("manifest.json"))
        try requireRegularFile(source.appendingPathComponent("content-script.js"))
        try requireRegularFile(source.appendingPathComponent("service-worker.js"))
        try requireRegularFile(helper)
        let managedRoot = applicationSupport.appendingPathComponent("SofaRemote/Integrations")
        let destination = managedRoot.appendingPathComponent("ChromeExtension", isDirectory: true)
        let executable = managedRoot.appendingPathComponent("SofaRemoteNativeHost")
        let manifest =
            applicationSupport
            .appendingPathComponent("Google/Chrome/NativeMessagingHosts")
            .appendingPathComponent(Self.nativeHostName + ".json")
        try rejectLink(executable)
        try rejectLink(manifest)
        try installDirectory(source, at: destination)
        try writePrivate(Data(contentsOf: helper), to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let value: [String: Any] = [
            "name": Self.nativeHostName,
            "description": "Sofa Remote local media bridge",
            "path": executable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"]
        ]
        try writePrivate(
            JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: manifest)
        return destination
    }

    private var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support")
    }

    private func ensureDirectory(_ directory: URL) throws {
        // Reject existing linked ancestors before writing a private credential file.
        var current = directory
        while current.path != home.path, current.path != "/" {
            try rejectLink(current)
            current.deleteLastPathComponent()
        }
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw IntegrationSetupError.linkedDestination
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw IntegrationSetupError.missingResources
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try rejectLink(url)
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".sofa-config-\(UUID().uuidString)")
        let descriptor = open(
            staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? files.removeItem(at: staging) }
        try handle.write(contentsOf: data)
        guard rename(staging.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func installDirectory(_ source: URL, at destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw IntegrationSetupError.missingResources
        }
        let parent = destination.deletingLastPathComponent()
        try ensureDirectory(parent)
        try rejectLink(destination)
        let staging = parent.appendingPathComponent(".sofa-install-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".sofa-backup-\(UUID().uuidString)")
        try files.copyItem(at: source, to: staging)
        defer { try? files.removeItem(at: staging) }
        let existed = files.fileExists(atPath: destination.path)
        if existed { try files.moveItem(at: destination, to: backup) }
        do {
            try files.moveItem(at: staging, to: destination)
        } catch {
            if existed { try? files.moveItem(at: backup, to: destination) }
            throw error
        }
        if existed { try files.removeItem(at: backup) }
    }
}

public enum IntegrationSetupError: Error, LocalizedError {
    case missingResources
    case invalidPreferences
    case linkedDestination

    public var errorDescription: String? {
        switch self {
        case .missingResources:
            "This app is missing its media integration files. Reinstall Sofa Remote."
        case .invalidPreferences: "IINA's existing plugin settings could not be read."
        case .linkedDestination: "A linked integration destination cannot be replaced."
        }
    }
}
