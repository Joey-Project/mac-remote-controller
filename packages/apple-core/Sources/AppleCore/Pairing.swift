import CryptoKit
import Foundation
import Security

/// A short-lived, out-of-band invitation. Treat the entire URL as a secret.
public struct PairingInvitation: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let serviceName: String
    public let certificateSHA256: String
    public let token: String
    public let expiresAt: Date

    public init(serviceName: String, certificateSHA256: String, token: String, expiresAt: Date) {
        protocolVersion = 1
        self.serviceName = serviceName
        self.certificateSHA256 = certificateSHA256
        self.token = token
        self.expiresAt = Date(timeIntervalSince1970: floor(expiresAt.timeIntervalSince1970))
    }

    public func url() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(self)
        return "sofaremote://pair/" + data.base64EncodedString()
    }

    public static func parse(_ value: String, now: Date = Date()) throws -> Self {
        let prefix = "sofaremote://pair/"
        guard value.utf8.count <= 4096, value.hasPrefix(prefix),
            let data = Data(base64Encoded: String(value.dropFirst(prefix.count)))
        else { throw PairingError.invalidInvitation }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let invitation = try decoder.decode(Self.self, from: data)
        guard invitation.protocolVersion == 1,
            UUID(uuidString: invitation.serviceName) != nil,
            invitation.certificateSHA256.count == 64,
            invitation.certificateSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
            Data(base64Encoded: invitation.token)?.count == 32,
            invitation.expiresAt > now,
            invitation.expiresAt.timeIntervalSince(now) <= 300
        else { throw PairingError.invalidInvitation }
        return invitation
    }
}

public struct PairedMac: Codable, Equatable, Sendable {
    public let serviceName: String
    public let name: String
    public let certificateSHA256: String
    public let token: String

    public init(serviceName: String, name: String, certificateSHA256: String, token: String) {
        self.serviceName = serviceName
        self.name = name
        self.certificateSHA256 = certificateSHA256
        self.token = token
    }
}

public enum PairingError: Error, LocalizedError {
    case invalidInvitation
    case secureStorage(OSStatus)
    case randomGeneration

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation:
            "The pairing invitation is invalid or expired. Open a new one on the Mac."
        case .secureStorage: "Secure storage is unavailable. Unlock the device and try again."
        case .randomGeneration: "A secure pairing secret could not be created."
        }
    }
}

public enum PairingSecurity {
    public static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PairingError.randomGeneration
        }
        return Data(bytes).base64EncodedString()
    }

    public static func fingerprint(_ certificate: Data) -> String {
        SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
    }

    /// Both inputs are digested to fixed-size values before comparison.
    public static func matches(_ first: String, _ second: String) -> Bool {
        let left = SHA256.hash(data: Data(first.utf8))
        let right = SHA256.hash(data: Data(second.utf8))
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum SecureStore {
    private static let service = "com.joeyteng.sofaremote"

    public static func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PairingError.secureStorage(status)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PairingError.secureStorage(addStatus) }
        } else if status != errSecSuccess {
            throw PairingError.secureStorage(status)
        }
    }

    private static func baseQuery(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }
}
