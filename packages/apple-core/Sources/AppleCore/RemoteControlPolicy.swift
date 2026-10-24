import Foundation

public struct PendingCommandMetadata: Sendable, Equatable {
    public let connectionID: String
    public let requestID: String
    public let sequence: UInt64
    public let requiresSessionTeardownOnFailure: Bool

    public init(
        connectionID: String, requestID: String, sequence: UInt64, command: RemoteCommand
    ) {
        self.connectionID = connectionID
        self.requestID = requestID
        self.sequence = sequence
        requiresSessionTeardownOnFailure = command.name == .pointerButtonUp
    }

    public func matchesResult(_ message: WireMessage) -> Bool {
        message.type == .result && message.connectionID == connectionID
            && message.requestID == requestID && message.sequence == sequence
    }

    public func requiresSessionTeardown(for message: WireMessage) -> Bool {
        requiresSessionTeardownOnFailure && matchesResult(message) && message.error != nil
    }
}

public enum PointerOwnershipPolicy {
    public static func blocks(
        _ command: RemoteCommand, heldBy pointerOwner: UUID?, requester: UUID
    ) -> Bool {
        guard let pointerOwner, pointerOwner != requester else { return false }
        switch command.name {
        case .pointerMove, .pointerClick, .pointerScroll, .pointerButtonDown, .pointerButtonUp:
            return true
        default: return false
        }
    }
}
