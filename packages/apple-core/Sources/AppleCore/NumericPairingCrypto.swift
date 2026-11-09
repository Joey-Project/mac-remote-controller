import CryptoKit
import Foundation
import SRP

/// These authenticated labels also bind the SRP exchange to the actual TLS leaf.
public struct NumericPairingContext: Sendable {
    public let requestID: UUID
    public let attemptID: UUID
    public let serviceName: String
    public let certificateSHA256: String
    public let deviceName: String
    public let macName: String

    public init(
        requestID: UUID, attemptID: UUID, serviceName: String, certificateSHA256: String,
        deviceName: String, macName: String
    ) {
        self.requestID = requestID
        self.attemptID = attemptID
        self.serviceName = serviceName
        self.certificateSHA256 = certificateSHA256
        self.deviceName = deviceName
        self.macName = macName
    }

    fileprivate func transcript(salt: Data, client: Data, server: Data) throws -> Data {
        guard UUID(uuidString: serviceName) != nil,
            certificateSHA256.count == 64,
            certificateSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
            !deviceName.isEmpty, deviceName.utf8.count <= WireLimits.maximumDeviceNameBytes,
            !macName.isEmpty, macName.utf8.count <= WireLimits.maximumDeviceNameBytes,
            salt.count == 32, client.count == 384, server.count == 384
        else { throw NumericPairingFailure.invalidHandshake }
        let labels =
            [
                "SofaRemote/SRP6a-3072-SHA256/v1", requestID.uuidString, attemptID.uuidString,
                serviceName, certificateSHA256, deviceName, macName
            ].map { Data($0.utf8) } + [salt, client, server]
        var transcript = Data()
        for label in labels {
            var size = UInt32(label.count).bigEndian
            withUnsafeBytes(of: &size) { transcript.append(contentsOf: $0) }
            transcript.append(label)
        }
        return Data(SHA256.hash(data: transcript))
    }
}

public struct NumericPairingChallenge: Sendable {
    public let salt: Data
    public let publicKey: Data

    public init(salt: Data, publicKey: Data) { self.salt = salt; self.publicKey = publicKey }
}

public struct NumericPairingProof: Sendable {
    public let proof: Data
    public let binding: Data

    public init(proof: Data, binding: Data) { self.proof = proof; self.binding = binding }
}

private enum NumericPairingBinding {
    static func key(secret: SRPKey, transcript: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret.bytes), salt: transcript,
            info: Data("SofaRemote/numeric-pairing/binding/v1".utf8), outputByteCount: 32)
    }

    static func data(role: String, transcript: Data, client: Data, server: Data = Data()) -> Data {
        Data(role.utf8) + transcript + client + server
    }

    static func proof(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func verify(_ proof: Data, key: SymmetricKey, data: Data) -> Bool {
        proof.count == 32
            && HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: data, using: key)
    }

    static func validateKey(_ data: Data) throws {
        guard data.count == 384, data.contains(where: { $0 != 0 }) else {
            throw NumericPairingFailure.invalidHandshake
        }
    }
}

/// All modular exponentiation and non-Sendable SRP keys stay off the input actor.
public actor NumericPairingClientCrypto {
    private let requestID: UUID
    private let client = SRPClient(configuration: SRPConfiguration<SHA256>(.N3072))
    private var password: String?
    private var keys: SRPKeyPair?
    private struct Confirmation {
        let key: SymmetricKey
        let transcript: Data
        let shared: SRPKey
        let publicKey: SRPKey
        let proof: Data
    }
    private var confirmation: Confirmation?

    public init(requestID: UUID) { self.requestID = requestID }

    public func begin(code: String) throws -> Data {
        cancel()
        guard NumericPairingCode.isValid(code) else { throw NumericPairingFailure.incorrectCode }
        password = code
        let keys = client.generateKeys()
        self.keys = keys
        return Data(keys.public.bytes)
    }

    public func answer(_ challenge: NumericPairingChallenge, context: NumericPairingContext) throws
        -> NumericPairingProof
    {
        guard context.requestID == requestID, let keys, let password else {
            throw NumericPairingFailure.invalidHandshake
        }
        self.password = nil
        self.keys = nil
        try NumericPairingBinding.validateKey(challenge.publicKey)
        let transcript = try context.transcript(
            salt: challenge.salt, client: Data(keys.public.bytes), server: challenge.publicKey)
        let shared = try client.calculateSharedSecret(
            username: requestID.uuidString, password: password, salt: [UInt8](challenge.salt),
            clientKeys: keys, serverPublicKey: SRPKey(challenge.publicKey))
        let proof = Data(
            client.calculateClientProof(
                username: requestID.uuidString, salt: [UInt8](challenge.salt),
                clientPublicKey: keys.public, serverPublicKey: SRPKey(challenge.publicKey),
                sharedSecret: shared))
        let key = NumericPairingBinding.key(secret: shared, transcript: transcript)
        confirmation = Confirmation(
            key: key, transcript: transcript, shared: shared,
            publicKey: keys.public, proof: proof)
        return NumericPairingProof(
            proof: proof,
            binding: NumericPairingBinding.proof(
                key: key,
                data: NumericPairingBinding.data(
                    role: "client", transcript: transcript, client: proof)))
    }

    public func accept(_ response: NumericPairingProof) throws -> Data {
        guard let confirmation else { throw NumericPairingFailure.invalidHandshake }
        self.confirmation = nil
        guard
            NumericPairingBinding.verify(
                response.binding, key: confirmation.key,
                data: NumericPairingBinding.data(
                    role: "server", transcript: confirmation.transcript,
                    client: confirmation.proof, server: response.proof))
        else { throw NumericPairingFailure.invalidHandshake }
        try client.verifyServerProof(
            serverProof: [UInt8](response.proof), clientProof: [UInt8](confirmation.proof),
            clientPublicKey: confirmation.publicKey, sharedSecret: confirmation.shared)
        return NumericPairingBinding.proof(
            key: confirmation.key,
            data: NumericPairingBinding.data(
                role: "finish", transcript: confirmation.transcript,
                client: confirmation.proof, server: response.proof))
    }

    public func cancel() { password = nil; keys = nil; confirmation = nil }
}

public actor NumericPairingServerCrypto {
    private let requestID: UUID
    private let configuration = SRPConfiguration<SHA256>(.N3072)
    private var password: String?
    private var verifier: (salt: [UInt8], key: SRPKey)?
    private struct Attempt {
        let keys: SRPKeyPair
        let publicKey: SRPKey
        let transcript: Data
    }
    private struct Confirmation {
        let key: SymmetricKey
        let transcript: Data
        let client: Data
        let server: Data
    }
    private var attempt: Attempt?
    private var confirmation: Confirmation?

    public init(requestID: UUID, code: String) throws {
        guard NumericPairingCode.isValid(code) else { throw NumericPairingFailure.invalidHandshake }
        self.requestID = requestID
        password = code
    }

    public func challenge(clientPublicKey: Data, context: NumericPairingContext) throws
        -> NumericPairingChallenge
    {
        attempt = nil; confirmation = nil
        guard context.requestID == requestID else { throw NumericPairingFailure.invalidHandshake }
        try NumericPairingBinding.validateKey(clientPublicKey)
        if verifier == nil {
            guard let password else { throw NumericPairingFailure.invalidHandshake }
            let value = SRPClient(configuration: configuration).generateSaltAndVerifier(
                username: requestID.uuidString, password: password)
            verifier = (value.salt, value.verifier)
            self.password = nil
        }
        guard let verifier else { throw NumericPairingFailure.invalidHandshake }
        let keys = SRPServer(configuration: configuration).generateKeys(verifier: verifier.key)
        let transcript = try context.transcript(
            salt: Data(verifier.salt), client: clientPublicKey,
            server: Data(keys.public.bytes))
        attempt = Attempt(keys: keys, publicKey: SRPKey(clientPublicKey), transcript: transcript)
        return NumericPairingChallenge(
            salt: Data(verifier.salt), publicKey: Data(keys.public.bytes))
    }

    public func verify(_ response: NumericPairingProof) throws -> NumericPairingProof {
        guard let attempt, let verifier else { throw NumericPairingFailure.invalidHandshake }
        self.attempt = nil
        let server = SRPServer(configuration: configuration)
        let shared = try server.calculateSharedSecret(
            clientPublicKey: attempt.publicKey,
            serverKeys: attempt.keys, verifier: verifier.key)
        let key = NumericPairingBinding.key(secret: shared, transcript: attempt.transcript)
        guard
            NumericPairingBinding.verify(
                response.binding, key: key,
                data: NumericPairingBinding.data(
                    role: "client", transcript: attempt.transcript, client: response.proof))
        else { throw NumericPairingFailure.incorrectCode }
        let proof = Data(
            try server.verifyClientProof(
                proof: [UInt8](response.proof),
                username: requestID.uuidString, salt: verifier.salt,
                clientPublicKey: attempt.publicKey,
                serverPublicKey: attempt.keys.public, sharedSecret: shared))
        confirmation = Confirmation(
            key: key, transcript: attempt.transcript, client: response.proof, server: proof)
        return NumericPairingProof(
            proof: proof,
            binding: NumericPairingBinding.proof(
                key: key,
                data: NumericPairingBinding.data(
                    role: "server", transcript: attempt.transcript,
                    client: response.proof, server: proof)))
    }

    public func finish(_ binding: Data) throws {
        guard let confirmation else { throw NumericPairingFailure.invalidHandshake }
        self.confirmation = nil
        guard
            NumericPairingBinding.verify(
                binding, key: confirmation.key,
                data: NumericPairingBinding.data(
                    role: "finish", transcript: confirmation.transcript,
                    client: confirmation.client, server: confirmation.server))
        else { throw NumericPairingFailure.invalidHandshake }
        cancel()
    }

    public func cancel() { password = nil; verifier = nil; attempt = nil; confirmation = nil }
}
