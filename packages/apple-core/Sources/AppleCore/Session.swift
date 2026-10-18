import Foundation

public struct AcceptedCommand: Sendable, Equatable {
    public let requestID: String
    public let sequence: UInt64
    public let command: RemoteCommand

    public init(requestID: String, sequence: UInt64, command: RemoteCommand) {
        self.requestID = requestID
        self.sequence = sequence
        self.command = command
    }
}

/// Tracks command ordering for one authenticated connection.
public struct ServerSession: Sendable, Equatable {
    public let connectionID: String
    public private(set) var lastSequence: UInt64 = 0

    public init(connectionID: String) {
        self.connectionID = connectionID
    }

    /// Accepts strictly increasing sequence numbers; gaps are allowed.
    /// Once a valid identity and new sequence are seen, the sequence is consumed
    /// before command value validation so a rejected payload cannot desynchronize
    /// a client that increments its sequence before sending.
    public mutating func accept(_ message: WireMessage) throws -> AcceptedCommand {
        guard message.protocolVersion == WireLimits.protocolVersion else {
            throw WireProtocolError.unsupportedVersion(message.protocolVersion)
        }
        guard message.type == .command else {
            throw WireProtocolError.invalidEnvelope("session accepts command messages only")
        }
        try message.validateEnvelope()
        guard message.connectionID == connectionID else {
            throw WireProtocolError.invalidConnectionID
        }
        guard let requestID = message.requestID, UUID(uuidString: requestID) != nil,
            let sequence = message.sequence, sequence > 0, sequence <= WireLimits.maximumSequence
        else {
            throw WireProtocolError.invalidEnvelope(
                "command identity requires UUID requestId and positive exact sequence")
        }
        guard sequence > lastSequence else {
            throw WireProtocolError.invalidSequence(expected: lastSequence + 1, received: sequence)
        }

        lastSequence = sequence
        guard let command = message.command else {
            throw WireProtocolError.invalidEnvelope("command message requires command")
        }
        try command.validate()
        return AcceptedCommand(requestID: requestID, sequence: sequence, command: command)
    }

    public func makeResult(
        for accepted: AcceptedCommand,
        error: RemoteError? = nil
    ) -> WireMessage {
        WireMessage(
            type: .result,
            connectionID: connectionID,
            requestID: accepted.requestID,
            sequence: accepted.sequence,
            error: error
        )
    }
}
