import Foundation

public enum MessageType: String, Codable, Sendable, Equatable {
    case authenticate
    case welcome
    case command
    case result
    case state
    case ping
    case pong
    case disconnect
}

public enum CommandName: String, Codable, Sendable, Equatable {
    case pointerMove = "pointer.move"
    case pointerClick = "pointer.click"
    case pointerScroll = "pointer.scroll"
    case pointerButtonDown = "pointer.button.down"
    case pointerButtonUp = "pointer.button.up"
    case systemShortcut = "system.shortcut"
    case keyboardText = "keyboard.text"
    case keyboardKey = "keyboard.key"
    case systemVolumeSet = "system.volume.set"
    case mediaControl = "media.control"
}

public enum RemoteKey: String, Codable, Sendable, Equatable {
    case returnKey = "return"
    case escape
    case backspace
    case space
    case left
    case right
    case up
    case down
}

public enum PointerButton: String, Codable, Sendable, Equatable {
    case left
    case right
}

/// Fixed public macOS shortcuts; arbitrary key codes and shell actions are never accepted.
public enum SystemShortcut: String, Codable, Sendable, Equatable {
    case missionControl = "mission-control"
    case appExpose = "app-expose"
    case previousSpace = "previous-space"
    case nextSpace = "next-space"
}

public enum WireCapabilities {
    public static let roundTripProbe = "roundTripProbe.v1"
}

public struct RemoteError: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct WireMessage: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var type: MessageType
    public var authToken: String?
    public var deviceName: String?
    public var connectionID: String?
    public var requestID: String?
    public var sequence: UInt64?
    public var command: RemoteCommand?
    public var state: RemoteState?
    public var error: RemoteError?

    public init(
        protocolVersion: Int = 1,
        type: MessageType,
        authToken: String? = nil,
        deviceName: String? = nil,
        connectionID: String? = nil,
        requestID: String? = nil,
        sequence: UInt64? = nil,
        command: RemoteCommand? = nil,
        state: RemoteState? = nil,
        error: RemoteError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.authToken = authToken
        self.deviceName = deviceName
        self.connectionID = connectionID
        self.requestID = requestID
        self.sequence = sequence
        self.command = command
        self.state = state
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion
        case type
        case authToken
        case deviceName
        case connectionID = "connectionId"
        case requestID = "requestId"
        case sequence
        case command
        case state
        case error
    }

    public func validate() throws {
        try validate(validateCommandValues: true)
    }

    func validateEnvelope() throws {
        try validate(validateCommandValues: false)
    }

    private func validate(validateCommandValues: Bool) throws {
        guard protocolVersion == WireLimits.protocolVersion else {
            throw WireProtocolError.unsupportedVersion(protocolVersion)
        }
        switch type {
        case .authenticate:
            try validateAuthenticate()
        case .welcome:
            try validateWelcome()
        case .command:
            try validateCommand(validateCommandValues: validateCommandValues)
        case .result:
            try validateResult()
        case .state:
            try validateState()
        case .ping, .pong:
            try validatePing()
        case .disconnect:
            try validateDisconnect()
        }
    }

    private func validateAuthenticate() throws {
        guard let authToken, !authToken.isEmpty,
            authToken.utf8.count <= WireLimits.maximumAuthTokenBytes,
            let deviceName, !deviceName.isEmpty,
            deviceName.utf8.count <= WireLimits.maximumDeviceNameBytes
        else {
            throw WireProtocolError.invalidEnvelope(
                "authenticate requires authToken and deviceName")
        }
        guard connectionID == nil, requestID == nil, sequence == nil, command == nil,
            state == nil, error == nil
        else {
            throw WireProtocolError.invalidEnvelope(
                "authenticate contains fields from another message type")
        }
    }

    private func validateWelcome() throws {
        guard let connectionID, !connectionID.isEmpty,
            connectionID.utf8.count <= WireLimits.maximumIdentityBytes,
            let state
        else {
            throw WireProtocolError.invalidEnvelope("welcome requires connectionId and state")
        }
        guard requestID == nil, sequence == nil, command == nil, error == nil, deviceName == nil
        else {
            throw WireProtocolError.invalidEnvelope(
                "welcome contains fields from another message type")
        }
        if let authToken, hasInvalidAuthToken(authToken) {
            throw WireProtocolError.invalidEnvelope("welcome authToken is empty or too long")
        }
        try state.validate()
    }

    private func hasInvalidAuthToken(_ token: String) -> Bool {
        token.isEmpty || token.utf8.count > WireLimits.maximumAuthTokenBytes
    }

    private func validateCommand(validateCommandValues: Bool) throws {
        try validateCommandIdentity()
        guard let command else {
            throw WireProtocolError.invalidEnvelope("command message requires command")
        }
        if validateCommandValues { try command.validate() }
        guard authToken == nil, deviceName == nil, state == nil, error == nil else {
            throw WireProtocolError.invalidEnvelope(
                "command contains fields from another message type")
        }
    }

    private func validateResult() throws {
        try validateCommandIdentity()
        guard command == nil, state == nil, authToken == nil, deviceName == nil else {
            throw WireProtocolError.invalidEnvelope(
                "result contains fields from another message type")
        }
        guard let error else { return }
        guard !error.code.isEmpty, error.code.utf8.count <= WireLimits.maximumErrorCodeBytes,
            !error.message.isEmpty, error.message.utf8.count <= WireLimits.maximumErrorMessageBytes
        else {
            throw WireProtocolError.invalidEnvelope("result error is empty or too long")
        }
    }

    private func validateState() throws {
        guard let connectionID, !connectionID.isEmpty,
            connectionID.utf8.count <= WireLimits.maximumIdentityBytes,
            let state
        else {
            throw WireProtocolError.invalidEnvelope("state message requires connectionId and state")
        }
        try state.validate()
        guard requestID == nil, sequence == nil, command == nil, error == nil, authToken == nil,
            deviceName == nil
        else {
            throw WireProtocolError.invalidEnvelope(
                "state contains fields from another message type")
        }
    }

    private func validatePing() throws {
        guard let connectionID, !connectionID.isEmpty,
            connectionID.utf8.count <= WireLimits.maximumIdentityBytes,
            let requestID, UUID(uuidString: requestID) != nil,
            let sequence, sequence > 0, sequence <= WireLimits.maximumSequence
        else {
            throw WireProtocolError.invalidEnvelope(
                "ping requires connectionId, requestId, and sequence")
        }
        guard authToken == nil, deviceName == nil, command == nil, state == nil, error == nil else {
            throw WireProtocolError.invalidEnvelope(
                "ping contains fields from another message type")
        }
    }

    private func validateDisconnect() throws {
        guard let connectionID, !connectionID.isEmpty,
            connectionID.utf8.count <= WireLimits.maximumIdentityBytes,
            authToken == nil, deviceName == nil, requestID == nil, sequence == nil,
            command == nil, state == nil, error == nil
        else { throw WireProtocolError.invalidEnvelope("disconnect has invalid fields") }
    }

    private func validateCommandIdentity() throws {
        guard let connectionID, !connectionID.isEmpty,
            connectionID.utf8.count <= WireLimits.maximumIdentityBytes,
            let requestID, UUID(uuidString: requestID) != nil,
            let sequence, sequence > 0, sequence <= WireLimits.maximumSequence
        else {
            throw WireProtocolError.invalidEnvelope(
                "command identity requires connectionId, UUID requestId, and positive exact sequence"
            )
        }
    }
}

public enum WireLimits {
    public static let protocolVersion = 1
    public static let maximumMessageBytes = 64 * 1024
    public static let maximumTextBytes = 4096
    public static let maximumSequence: UInt64 = 9_007_199_254_740_991
    public static let maximumIdentityBytes = 128
    public static let maximumAuthTokenBytes = 4096
    public static let maximumDeviceNameBytes = 256
    public static let maximumMediaTargetIDBytes = 128
    public static let maximumMediaTargetNameBytes = 256
    public static let maximumMediaTargets = 64
    public static let maximumErrorCodeBytes = 64
    public static let maximumErrorMessageBytes = 1024
}

public enum WireProtocolError: Error, Sendable, Equatable {
    case malformedMessage(String)
    case unsupportedVersion(Int)
    case invalidEnvelope(String)
    case invalidCommand(String)
    case invalidConnectionID
    case invalidSequence(expected: UInt64, received: UInt64)
}

public enum WireCodec {
    public static func decode(_ data: Data) throws -> WireMessage {
        guard data.count <= WireLimits.maximumMessageBytes else {
            throw WireProtocolError.malformedMessage("message exceeds 64 KiB")
        }
        let message: WireMessage
        do {
            message = try JSONDecoder().decode(WireMessage.self, from: data)
        } catch {
            throw WireProtocolError.malformedMessage(String(describing: error))
        }
        try message.validateEnvelope()
        return message
    }

    public static func encode(_ message: WireMessage) throws -> Data {
        try message.validate()
        let data = try JSONEncoder().encode(message)
        guard data.count <= WireLimits.maximumMessageBytes else {
            throw WireProtocolError.malformedMessage("message exceeds 64 KiB")
        }
        return data
    }
}
