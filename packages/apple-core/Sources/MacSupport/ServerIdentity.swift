#if os(macOS)
    import AppleCore
    import Foundation
    import Security
    import X509

    public struct LocalIdentity {
        public let identity: SecIdentity
        public let certificateDER: Data
        public let serviceName: String

        public init(identity: SecIdentity, certificateDER: Data, serviceName: String) {
            self.identity = identity
            self.certificateDER = certificateDER
            self.serviceName = serviceName
        }
    }

    public enum ServerIdentity {
        private static let storageAccount = "server-identity"
        private static let privateKeyTag = Data("com.joeyteng.sofaremote.tls.key".utf8)
        private static let certificateLifetime: TimeInterval = 10 * 365 * 24 * 60 * 60

        @MainActor
        public static func loadOrCreate() throws -> LocalIdentity {
            let storedRecord = try SecureStore.load(StoredIdentity.self, account: storageAccount)
            let loadedPrivateKey = try loadPrivateKey()

            if storedRecord != nil, loadedPrivateKey == nil {
                throw ServerIdentityError.missingPrivateKey
            }

            let privateKey: SecKey
            if let loadedPrivateKey {
                privateKey = loadedPrivateKey
            } else {
                privateKey = try createPrivateKey()
            }

            let record: StoredIdentity
            if let storedRecord {
                record = storedRecord
            } else {
                record = try createRecord(privateKey: privateKey)
                try SecureStore.save(record, account: storageAccount)
            }

            guard UUID(uuidString: record.serviceName) != nil,
                let certificate = SecCertificateCreateWithData(nil, record.certificateDER as CFData)
            else {
                throw ServerIdentityError.invalidStoredIdentity
            }

            let parsedCertificate: Certificate
            do {
                parsedCertificate = try Certificate(certificate)
            } catch {
                throw ServerIdentityError.invalidStoredIdentity
            }
            let signingKey = try Certificate.PrivateKey(privateKey)
            guard parsedCertificate.publicKey == signingKey.publicKey else {
                throw ServerIdentityError.invalidStoredIdentity
            }

            let now = Date()
            guard parsedCertificate.notValidAfter > now else {
                throw ServerIdentityError.expiredCertificate(parsedCertificate.notValidAfter)
            }
            guard parsedCertificate.notValidBefore <= now else {
                throw ServerIdentityError.certificateNotYetValid(parsedCertificate.notValidBefore)
            }

            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
            guard status == errSecSuccess, let identity else {
                throw ServerIdentityError.identityUnavailable(status)
            }

            return LocalIdentity(
                identity: identity,
                certificateDER: record.certificateDER,
                serviceName: record.serviceName
            )
        }

        private static func loadPrivateKey() throws -> SecKey? {
            let query: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrApplicationTag: privateKeyTag,
                kSecReturnRef: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw ServerIdentityError.keychain(status)
            }
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
                throw ServerIdentityError.invalidKeyResult
            }
            return unsafeDowncast(result, to: SecKey.self)
        }

        private static func createPrivateKey() throws -> SecKey {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits: 256,
                kSecPrivateKeyAttrs: [
                    kSecAttrIsPermanent: true,
                    kSecAttrApplicationTag: privateKeyTag
                ]
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                let message =
                    error?.takeRetainedValue().localizedDescription ?? "unknown keychain error"
                throw ServerIdentityError.keyCreation(message)
            }
            return key
        }

        private static func createRecord(privateKey: SecKey) throws -> StoredIdentity {
            let serviceName = UUID().uuidString.lowercased()
            let distinguishedName = try DistinguishedName {
                CommonName("Sofa Remote \(serviceName)")
            }
            let signingKey = try Certificate.PrivateKey(privateKey)
            let now = Date()
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: signingKey.publicKey,
                notValidBefore: now.addingTimeInterval(-5 * 60),
                notValidAfter: now.addingTimeInterval(certificateLifetime),
                issuer: distinguishedName,
                subject: distinguishedName,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                },
                issuerPrivateKey: signingKey
            )
            let secCertificate = try SecCertificate.makeWithCertificate(certificate)
            let certificateDER = SecCertificateCopyData(secCertificate) as Data
            return StoredIdentity(certificateDER: certificateDER, serviceName: serviceName)
        }
    }

    private struct StoredIdentity: Codable {
        let certificateDER: Data
        let serviceName: String
    }

    private enum ServerIdentityError: LocalizedError {
        case keychain(OSStatus)
        case keyCreation(String)
        case invalidKeyResult
        case missingPrivateKey
        case invalidStoredIdentity
        case expiredCertificate(Date)
        case certificateNotYetValid(Date)
        case identityUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                "The Mac TLS key could not be read from Keychain (status \(status))."
            case .keyCreation(let message):
                "A Mac TLS key could not be created: \(message)."
            case .invalidKeyResult:
                "Keychain returned an unexpected object for the Mac TLS private key."
            case .missingPrivateKey:
                "The saved Mac TLS certificate has no matching private key. "
                    + "Restore the key or reset the saved server identity explicitly."
            case .invalidStoredIdentity:
                "The saved Mac TLS identity is malformed. "
                    + "Reset the saved server identity explicitly before pairing again."
            case .expiredCertificate(let date):
                "The saved Mac TLS certificate expired on \(date.formatted()). "
                    + "Reset the saved server identity explicitly before pairing again."
            case .certificateNotYetValid(let date):
                "The saved Mac TLS certificate is not valid before \(date.formatted()). "
                    + "Check the Mac's clock or reset the saved server identity explicitly."
            case .identityUnavailable(let status):
                "The saved Mac TLS certificate could not be matched with its private key (status \(status))."
            }
        }
    }
#endif
