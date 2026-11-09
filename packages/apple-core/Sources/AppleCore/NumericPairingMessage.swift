import Foundation

public enum NumericPairingPhase: String, Codable, Sendable {
    case request, ready, hello, challenge, proof, accepted, finish, retry, rejected, cancel
}

public enum NumericPairingFailure: String, Codable, Error, LocalizedError, Sendable {
    case unavailable, busy, expired, tooManyAttempts, cancelled, invalidHandshake, incorrectCode

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Unlock the Mac and keep Sofa Remote open to pair."
        case .busy: "Another pairing request is open on the Mac. Try again after it closes."
        case .expired: "This pairing code has expired. Request a new code."
        case .tooManyAttempts: "Too many incorrect codes. Wait a minute, then request a new code."
        case .cancelled: "Pairing was cancelled on the Mac."
        case .invalidHandshake: "The pairing identity could not be verified. Request a new code."
        case .incorrectCode: "The code does not match. Check the four digits on the Mac."
        }
    }
}

/// A bounded enrollment-only exchange. The displayed PIN is never a wire field.
public struct NumericPairingMessage: Codable, Sendable, Equatable {
    public let id: UUID
    public let phase: NumericPairingPhase
    public var serviceName: String?
    public var name: String?
    public var expiresIn: Int?
    public var remainingAttempts: Int?
    public var attemptID: UUID?
    public var publicKey: Data?
    public var salt: Data?
    public var proof: Data?
    public var binding: Data?
    public var failure: NumericPairingFailure?

    public init(id: UUID, phase: NumericPairingPhase) {
        self.id = id
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, phase, serviceName, name, expiresIn, remainingAttempts, attemptID
        case publicKey, salt, proof, binding, failure
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: MediaDynamicCodingKey.self)
        guard
            Set(fields.allKeys.map(\.stringValue)).isSubset(
                of: Set(CodingKeys.allCases.map(\.rawValue)))
        else { throw WireProtocolError.invalidEnvelope("Unexpected numeric pairing fields") }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        phase = try values.decode(NumericPairingPhase.self, forKey: .phase)
        serviceName = try values.decodeIfPresent(String.self, forKey: .serviceName)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        expiresIn = try values.decodeIfPresent(Int.self, forKey: .expiresIn)
        remainingAttempts = try values.decodeIfPresent(Int.self, forKey: .remainingAttempts)
        attemptID = try values.decodeIfPresent(UUID.self, forKey: .attemptID)
        publicKey = try values.decodeIfPresent(Data.self, forKey: .publicKey)
        salt = try values.decodeIfPresent(Data.self, forKey: .salt)
        proof = try values.decodeIfPresent(Data.self, forKey: .proof)
        binding = try values.decodeIfPresent(Data.self, forKey: .binding)
        failure = try values.decodeIfPresent(NumericPairingFailure.self, forKey: .failure)
        try validate()
    }

    public func validate() throws {
        let fields = Set(
            [
                serviceName.map { _ in "serviceName" }, name.map { _ in "name" },
                expiresIn.map { _ in "expiresIn" },
                remainingAttempts.map { _ in "remainingAttempts" },
                attemptID.map { _ in "attemptID" }, publicKey.map { _ in "publicKey" },
                salt.map { _ in "salt" }, proof.map { _ in "proof" },
                binding.map { _ in "binding" }, failure.map { _ in "failure" }
            ].compactMap { $0 })
        let required: Set<String>
        switch phase {
        case .request: required = ["serviceName", "name"]
        case .ready: required = ["serviceName", "name", "expiresIn", "remainingAttempts"]
        case .hello: required = ["publicKey"]
        case .challenge: required = ["attemptID", "publicKey", "salt"]
        case .proof, .accepted: required = ["attemptID", "proof", "binding"]
        case .finish: required = ["attemptID", "binding"]
        case .retry: required = ["expiresIn", "remainingAttempts"]
        case .rejected: required = ["failure"]
        case .cancel: required = []
        }
        guard fields == required,
            serviceName.map({ UUID(uuidString: $0) != nil }) ?? true,
            name.map({ !$0.isEmpty && $0.utf8.count <= WireLimits.maximumDeviceNameBytes }) ?? true,
            expiresIn.map({ (1...120).contains($0) }) ?? true,
            remainingAttempts.map({ (1...3).contains($0) }) ?? true,
            publicKey.map({ $0.count == 384 && $0.contains(where: { $0 != 0 }) }) ?? true,
            salt.map({ $0.count == 32 }) ?? true,
            proof.map({ $0.count == 32 }) ?? true,
            binding.map({ $0.count == 32 }) ?? true,
            failure != .incorrectCode
        else { throw WireProtocolError.invalidEnvelope("Invalid numeric pairing packet") }
    }
}

public enum NumericPairingCode {
    public static func isValid(_ value: String) -> Bool {
        value.utf8.count == 4 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    public static func generate(excluding previous: String? = nil) -> String {
        let value: UInt32
        if let previous, isValid(previous), let old = UInt32(previous) {
            value = (old + UInt32.random(in: 1..<10_000)) % 10_000
        } else {
            value = UInt32.random(in: 0..<10_000)
        }
        return String(format: "%04d", value)
    }
}
