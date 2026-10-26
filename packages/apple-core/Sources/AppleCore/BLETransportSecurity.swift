import CryptoKit
import Foundation
import Security

public enum BLETransportError: Error, Equatable {
    case invalidHandshake
    case authenticationFailed
    case oversizedFrame
    case invalidFrame
    case replayOrOutOfOrder
    case queueFull
}

public struct BLEAuthenticatedDevice: Sendable {
    public let deviceID: String
    public let deviceName: String
    public let session: BLECryptoSession
}

public enum BLETransportConstants {
    public static let serviceUUID = "68f48aee-4f87-4c4e-a109-dc53f25a1000"
    public static let inputCharacteristicUUID = "68f48aee-4f87-4c4e-a109-dc53f25a1001"
    public static let outputCharacteristicUUID = "68f48aee-4f87-4c4e-a109-dc53f25a1002"
    public static let maximumQueuedBytes = 1_048_576
}

/// Bounded, big-endian length-prefix framing for characteristic fragments.
public enum BLEFrameCodec {
    public static let maximumPayloadBytes = WireLimits.maximumMessageBytes + 64
    public static let maximumQueuedBytes = 1_048_576

    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes,
            payload.count <= Int(UInt32.max)
        else { throw BLETransportError.oversizedFrame }
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

public struct BLEFrameDecoder: Sendable {
    private var buffered = Data()

    public init() {}

    public var bufferedByteCount: Int { buffered.count }

    public mutating func append(_ fragment: Data) throws -> [Data] {
        guard fragment.count <= BLEFrameCodec.maximumPayloadBytes + 4,
            buffered.count + fragment.count <= BLEFrameCodec.maximumPayloadBytes + 4
        else { throw BLETransportError.oversizedFrame }
        buffered.append(fragment)
        var frames: [Data] = []
        while buffered.count >= 4 {
            let length = buffered.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= BLEFrameCodec.maximumPayloadBytes else {
                throw BLETransportError.oversizedFrame
            }
            let fullLength = 4 + Int(length)
            guard buffered.count >= fullLength else { break }
            frames.append(buffered.subdata(in: 4..<fullLength))
            buffered.removeSubrange(0..<fullLength)
        }
        return frames
    }
}

public enum BLEHandshake {
    private static let version = 1
    private static let domain = Data("SofaRemote.BLE.v1\0".utf8)

    private struct Packet: Codable {
        var version: Int = BLEHandshake.version
        var type: String
        var serviceName: String?
        var deviceName: String?
        var clientNonce: Data?
        var serverNonce: Data?
        var proof: Data?
    }

    public struct Client: Sendable {
        private let serviceName: String
        private let deviceName: String
        private var key: SymmetricKey?
        private var clientNonce: Data?
        private var helloSent = false
        private var finished = false

        public init(serviceName: String, deviceName: String, token: String) throws {
            guard let tokenData = Data(base64Encoded: token), tokenData.count == 32 else {
                throw BLETransportError.invalidHandshake
            }
            self.serviceName = serviceName
            self.deviceName = deviceName
            key = SymmetricKey(data: tokenData)
            clientNonce = try BLEHandshake.randomNonce()
        }

        public mutating func hello() throws -> Data {
            guard !helloSent, !finished, let clientNonce, let key else {
                throw BLETransportError.invalidHandshake
            }
            helloSent = true
            let transcript = BLEHandshake.transcript(
                serviceName: serviceName, deviceName: deviceName, clientNonce: clientNonce)
            let packet = Packet(
                type: "hello", serviceName: serviceName, deviceName: deviceName,
                clientNonce: clientNonce,
                proof: BLEHandshake.hmac(key: key, domain: "client", message: transcript))
            return try BLEHandshake.encode(packet)
        }

        public mutating func finish(after challengeData: Data) throws -> (
            message: Data, session: BLECryptoSession
        ) {
            guard helloSent, !finished, let clientNonce, let key else {
                throw BLETransportError.invalidHandshake
            }
            let challenge = try BLEHandshake.decode(challengeData)
            guard challenge.type == "challenge", challenge.version == BLEHandshake.version,
                let serverNonce = challenge.serverNonce, serverNonce.count == 32,
                let serverProof = challenge.proof
            else { throw BLETransportError.invalidHandshake }
            let transcript = BLEHandshake.transcript(
                serviceName: serviceName, deviceName: deviceName,
                clientNonce: clientNonce, serverNonce: serverNonce)
            guard
                BLEHandshake.matches(
                    serverProof,
                    BLEHandshake.hmac(key: key, domain: "server", message: transcript))
            else { throw BLETransportError.authenticationFailed }
            let finish = Packet(
                type: "finish",
                proof: BLEHandshake.hmac(key: key, domain: "finish", message: transcript))
            let result = (
                message: try BLEHandshake.encode(finish),
                session: BLECryptoSession(
                    key: key, clientNonce: clientNonce, serverNonce: serverNonce, role: .client)
            )
            finished = true
            self.key = nil
            self.clientNonce = nil
            return result
        }
    }

    public struct Server: Sendable {
        private let serviceName: String
        private let pairedTokens: [(id: String, token: String)]
        private var chosenID: String?
        private var chosenKey: SymmetricKey?
        private var clientNonce: Data?
        private var serverNonce: Data?
        private var deviceName: String?
        private var awaitingFinish = false
        private var finished = false

        public init(serviceName: String, pairedTokens: [(id: String, token: String)]) {
            self.serviceName = serviceName
            self.pairedTokens = Array(pairedTokens.prefix(8))
        }

        public mutating func challenge(to helloData: Data) throws -> Data {
            guard !awaitingFinish, !finished else { throw BLETransportError.invalidHandshake }
            let hello = try BLEHandshake.decode(helloData)
            guard hello.type == "hello", hello.version == BLEHandshake.version,
                hello.serviceName == serviceName,
                let deviceName = hello.deviceName, !deviceName.isEmpty,
                deviceName.utf8.count <= WireLimits.maximumDeviceNameBytes,
                let clientNonce = hello.clientNonce, clientNonce.count == 32,
                let proof = hello.proof
            else { throw BLETransportError.invalidHandshake }
            let transcript = BLEHandshake.transcript(
                serviceName: serviceName, deviceName: deviceName, clientNonce: clientNonce)
            guard
                let match = pairedTokens.first(where: { pair in
                    guard let data = Data(base64Encoded: pair.token), data.count == 32 else {
                        return false
                    }
                    return BLEHandshake.matches(
                        proof,
                        BLEHandshake.hmac(
                            key: SymmetricKey(data: data), domain: "client", message: transcript))
                }), let tokenData = Data(base64Encoded: match.token), tokenData.count == 32
            else {
                throw BLETransportError.authenticationFailed
            }
            let key = SymmetricKey(data: tokenData)
            let serverNonce = try BLEHandshake.randomNonce()
            let fullTranscript = BLEHandshake.transcript(
                serviceName: serviceName, deviceName: deviceName,
                clientNonce: clientNonce, serverNonce: serverNonce)
            chosenID = match.id
            chosenKey = key
            self.clientNonce = clientNonce
            self.serverNonce = serverNonce
            self.deviceName = deviceName
            awaitingFinish = true
            return try BLEHandshake.encode(
                Packet(
                    type: "challenge", serverNonce: serverNonce,
                    proof: BLEHandshake.hmac(key: key, domain: "server", message: fullTranscript)))
        }

        public mutating func finish(_ finishData: Data) throws -> BLEAuthenticatedDevice {
            guard awaitingFinish, !finished else { throw BLETransportError.invalidHandshake }
            let finish = try BLEHandshake.decode(finishData)
            guard finish.type == "finish", finish.version == BLEHandshake.version,
                let key = chosenKey, let id = chosenID,
                let clientNonce, let serverNonce, let deviceName,
                let proof = finish.proof
            else { throw BLETransportError.invalidHandshake }
            let transcript = BLEHandshake.transcript(
                serviceName: serviceName, deviceName: deviceName,
                clientNonce: clientNonce, serverNonce: serverNonce)
            guard
                BLEHandshake.matches(
                    proof, BLEHandshake.hmac(key: key, domain: "finish", message: transcript))
            else { throw BLETransportError.authenticationFailed }
            let result = BLEAuthenticatedDevice(
                deviceID: id, deviceName: deviceName,
                session: BLECryptoSession(
                    key: key, clientNonce: clientNonce, serverNonce: serverNonce, role: .server)
            )
            finished = true
            awaitingFinish = false
            chosenKey = nil
            chosenID = nil
            self.clientNonce = nil
            self.serverNonce = nil
            self.deviceName = nil
            return result
        }
    }

    private static func transcript(
        serviceName: String, deviceName: String, clientNonce: Data, serverNonce: Data? = nil
    ) -> Data {
        var data = domain
        for value in [
            Data(serviceName.utf8), Data(deviceName.utf8), clientNonce, serverNonce ?? Data()
        ] {
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(value)
        }
        return data
    }

    private static func hmac(key: SymmetricKey, domain label: String, message: Data) -> Data {
        var input = Data(label.utf8)
        input.append(0)
        input.append(message)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    private static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BLETransportError.invalidHandshake
        }
        return Data(bytes)
    }

    private static func encode(_ packet: Packet) throws -> Data {
        var result = Data([0x01])
        result.append(try JSONEncoder().encode(packet))
        guard result.count <= 512 else { throw BLETransportError.oversizedFrame }
        return result
    }

    private static func decode(_ data: Data) throws -> Packet {
        guard data.count <= 512, data.first == 0x01 else {
            throw BLETransportError.invalidHandshake
        }
        do { return try JSONDecoder().decode(Packet.self, from: data.dropFirst()) } catch {
            throw BLETransportError.invalidHandshake
        }
    }
}

public struct BLECryptoSession: Sendable {
    public enum Role: Sendable, Equatable { case client, server }
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sentSequence: UInt64 = 0
    private var receivedSequence: UInt64 = 0

    fileprivate init(key: SymmetricKey, clientNonce: Data, serverNonce: Data, role: Role) {
        var salt = clientNonce
        salt.append(serverNonce)
        func derive(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: key, salt: salt,
                info: Data("SofaRemote.BLE.v1.\(direction)".utf8), outputByteCount: 32)
        }
        if role == .client {
            sendKey = derive("client-to-server")
            receiveKey = derive("server-to-client")
        } else {
            sendKey = derive("server-to-client")
            receiveKey = derive("client-to-server")
        }
    }

    public mutating func seal(_ message: WireMessage) throws -> Data {
        let plaintext = try WireCodec.encode(message)
        guard sentSequence < WireLimits.maximumSequence else {
            throw BLETransportError.replayOrOutOfOrder
        }
        sentSequence += 1
        let sequence = sentSequence.bigEndianData
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + sequence)
        let sealed = try ChaChaPoly.seal(
            plaintext, using: sendKey, nonce: nonce, authenticating: sequence)
        return Data([0x02]) + sequence + sealed.ciphertext + sealed.tag
    }

    public mutating func open(_ frame: Data) throws -> WireMessage {
        guard frame.count >= 1 + 8 + 16, frame.count <= BLEFrameCodec.maximumPayloadBytes,
            frame.first == 0x02
        else { throw BLETransportError.invalidFrame }
        let sequenceData = frame.subdata(in: 1..<9)
        let sequence = sequenceData.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard sequence == receivedSequence + 1 else { throw BLETransportError.replayOrOutOfOrder }
        let ciphertext = frame.subdata(in: 9..<(frame.count - 16))
        let tag = frame.suffix(16)
        let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + sequenceData)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: receiveKey, authenticating: sequenceData)
        } catch { throw BLETransportError.authenticationFailed }
        let message = try WireCodec.decode(plaintext)
        receivedSequence = sequence
        return message
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
