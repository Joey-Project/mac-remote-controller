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

        enum IdentityLoadDecision: Equatable {
            case createFresh
            case loadExisting
            case orphanedPrivateKey
            case missingPrivateKey

            static func resolve(hasStoredRecord: Bool, hasPrivateKey: Bool) -> Self {
                switch (hasStoredRecord, hasPrivateKey) {
                case (false, false): .createFresh
                case (true, true): .loadExisting
                case (false, true): .orphanedPrivateKey
                case (true, false): .missingPrivateKey
                }
            }
        }

        enum IdentityLoadTransaction {
            static func resolve<Key, Record>(
                decision: IdentityLoadDecision,
                loadExisting: () throws -> (Key, Record),
                createFresh: () throws -> (Key, Record)
            ) throws -> (Key, Record) {
                switch decision {
                case .createFresh:
                    try createFresh()
                case .loadExisting:
                    try loadExisting()
                case .orphanedPrivateKey:
                    throw ServerIdentityError.orphanedPrivateKey
                case .missingPrivateKey:
                    throw ServerIdentityError.missingPrivateKey
                }
            }
        }

        enum IdentityCreationTransaction {
            static func perform<Key, Record>(
                createKey: () throws -> Key,
                createRecord: (Key) throws -> Record,
                persistRecord: (Record) throws -> Void,
                rollbackKey: (Key) throws -> Void
            ) throws -> (Key, Record) {
                let key = try createKey()
                do {
                    let record = try createRecord(key)
                    try persistRecord(record)
                    return (key, record)
                } catch {
                    let primaryFailure = error
                    do {
                        try rollbackKey(key)
                    } catch {
                        throw ServerIdentityError.creationRollbackFailed(
                            primary: primaryFailure.localizedDescription,
                            rollback: error.localizedDescription
                        )
                    }
                    throw primaryFailure
                }
            }
        }

        @MainActor
        public static func loadOrCreate() throws -> LocalIdentity {
            let (privateKey, record) = try loadOrCreateMaterial()

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

        private static func loadOrCreateMaterial() throws -> (SecKey, StoredIdentity) {
            let storedRecord = try SecureStore.load(StoredIdentity.self, account: storageAccount)
            let loadedPrivateKey = try loadPrivateKey()
            let decision = IdentityLoadDecision.resolve(
                hasStoredRecord: storedRecord != nil,
                hasPrivateKey: loadedPrivateKey != nil
            )

            return try IdentityLoadTransaction.resolve(
                decision: decision,
                loadExisting: {
                    guard let loadedPrivateKey, let storedRecord else {
                        throw ServerIdentityError.invalidLoadDecision
                    }
                    return (loadedPrivateKey, storedRecord)
                },
                createFresh: {
                    try IdentityCreationTransaction.perform(
                        createKey: createPrivateKey,
                        createRecord: createRecord,
                        persistRecord: {
                            try SecureStore.save($0, account: storageAccount)
                        },
                        rollbackKey: deleteCreatedPrivateKey
                    )
                }
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

        private static func deleteCreatedPrivateKey(_ key: SecKey) throws {
            let persistentReference = try persistentReference(for: key)
            guard let persistentReference else { return }

            let query: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecMatchItemList: [persistentReference]
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ServerIdentityError.keyDeletion(status)
            }
        }

        private static func persistentReference(for key: SecKey) throws -> Data? {
            let query: [CFString: Any] = [
                kSecClass: kSecClassKey,
                kSecMatchItemList: [key],
                kSecReturnPersistentRef: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw ServerIdentityError.keychain(status)
            }
            guard let result, CFGetTypeID(result) == CFDataGetTypeID(), let data = result as? Data
            else {
                throw ServerIdentityError.invalidPersistentReference
            }
            return data
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
        case keyDeletion(OSStatus)
        case invalidPersistentReference
        case orphanedPrivateKey
        case missingPrivateKey
        case invalidLoadDecision
        case creationRollbackFailed(primary: String, rollback: String)
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
            case .keyDeletion(let status):
                "The newly created Mac TLS key could not be rolled back (status \(status))."
            case .invalidPersistentReference:
                "Keychain returned an unexpected persistent reference for the new TLS key."
            case .orphanedPrivateKey:
                "A Mac TLS private key exists without its saved certificate and service identity. "
                    + "Restore the saved server identity or reset the key explicitly."
            case .missingPrivateKey:
                "The saved Mac TLS certificate has no matching private key. "
                    + "Restore the key or reset the saved server identity explicitly."
            case .invalidLoadDecision:
                "The Mac TLS identity storage changed while it was being loaded."
            case .creationRollbackFailed(let primary, let rollback):
                "Mac TLS identity creation failed (\(primary)); cleanup also failed (\(rollback))."
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
