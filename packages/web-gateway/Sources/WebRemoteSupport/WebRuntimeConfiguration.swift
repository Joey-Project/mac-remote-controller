import Darwin
import CryptoKit
import Foundation

public enum WebConfigurationError: Error, Equatable {
    case notConfigured
    case unavailable
    case invalid
    case interfaceUnavailable
    case credentialsUnavailable
}

public struct WebRuntimeConfiguration: Codable, Sendable {
    public var schemaVersion: Int
    public var enabled: Bool
    public let endpoint: WebEndpoint
    public let dns: LANDNSConfiguration?
    public let interfaceName: String?

    public static func load(in root: URL) throws -> Self {
        try validateRoot(root)
        let data: Data
        do {
            data = try WebTLSMaterial.read(
                root.appendingPathComponent("configuration.json").path, limit: 16_384,
                privateFile: true)
        } catch WebTLSFileError.notFound { throw WebConfigurationError.notConfigured } catch {
            throw WebConfigurationError.unavailable
        }
        let configuration: Self
        do { configuration = try JSONDecoder().decode(Self.self, from: data) } catch {
            throw WebConfigurationError.invalid
        }
        try configuration.validate()
        return configuration
    }

    public func store(in root: URL) throws {
        try Self.validateRoot(root)
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = root.appendingPathComponent("configuration.json")
        try encoder.encode(self).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    public func currentEndpoint() throws -> WebEndpoint {
        guard let interfaceName else { return endpoint }
        guard let address = Self.privateAddress(of: interfaceName) else {
            throw WebConfigurationError.interfaceUnavailable
        }
        return try WebEndpoint(
            hostname: endpoint.hostname, port: endpoint.port, bindAddress: address,
            certificateChain: endpoint.certificateChain, privateKey: endpoint.privateKey)
    }

    public static func certificateFingerprint(_ endpoint: WebEndpoint) throws -> String {
        let data = try WebTLSMaterial.read(
            endpoint.certificateChain, limit: 65_536, privateFile: false)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func cloudflareToken(in root: URL) throws -> String {
        do {
            try validateRoot(root)
            let data = try WebTLSMaterial.read(
                root.appendingPathComponent("cloudflare-credentials.ini").path, limit: 8192,
                privateFile: true)
            guard let text = String(data: data, encoding: .utf8) else {
                throw WebConfigurationError.credentialsUnavailable
            }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
                separator: "=", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces) == "dns_cloudflare_api_token"
            else {
                throw WebConfigurationError.credentialsUnavailable
            }
            let token = parts[1].trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw WebConfigurationError.credentialsUnavailable
            }
            return token
        } catch { throw WebConfigurationError.credentialsUnavailable }
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw WebConfigurationError.invalid }
        try endpoint.validate()
        if let dns {
            try dns.validate()
            guard dns.hostname == endpoint.hostname else { throw WebConfigurationError.invalid }
        }
        if let interfaceName {
            guard !interfaceName.isEmpty, interfaceName.utf8.count <= 32,
                interfaceName.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                })
            else { throw WebConfigurationError.invalid }
        }
    }

    private static func validateRoot(_ root: URL) throws {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0 else {
            if errno == ENOENT { throw WebConfigurationError.notConfigured }
            throw WebConfigurationError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
            metadata.st_mode & 0o077 == 0
        else {
            throw WebConfigurationError.unavailable
        }
    }

    private static func privateAddress(of interfaceName: String) -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }
        var current = addresses
        var inspected = 0
        while let entry = current, inspected < 1024 {
            defer { current = entry.pointee.ifa_next; inspected += 1 }
            guard String(cString: entry.pointee.ifa_name) == interfaceName,
                let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil,
                    0, NI_NUMERICHOST) == 0
            else { continue }
            guard
                let value = String(
                    bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
            else { continue }
            if WebEndpoint.isPrivateIPv4(value) { return value }
        }
        return nil
    }
}
