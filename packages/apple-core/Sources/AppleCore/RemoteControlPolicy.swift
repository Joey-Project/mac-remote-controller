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

/// Correlates a local drag's button-down and button-up replies so a rejected
/// start does not turn its paired release error into a false safety failure.
public struct PointerDragResultPolicy: Sendable {
    public enum Outcome: Sendable, Equatable {
        case startAccepted(gestureID: String)
        case startRejected(gestureID: String)
        case releaseResultDeferred(gestureID: String)
        case releaseAccepted(gestureID: String)
        case releaseFailureDeferred(gestureID: String)
        case releaseFailureSuppressed(gestureID: String)
        case releaseFailureRequiresSessionTeardown(gestureID: String)
    }

    private struct Entry: Sendable {
        var startRequestID: String?
        var releaseRequestID: String?
        var releaseQueued = false
        var startSucceeded: Bool?
        var releaseSucceeded: Bool?
    }

    private var entries: [String: Entry] = [:]
    private var gestureByRequestID: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public func contains(gestureID: String) -> Bool { entries[gestureID] != nil }

    public mutating func begin(gestureID: String) {
        entries[gestureID] = Entry()
    }

    public mutating func registerStart(gestureID: String, requestID: String) {
        guard var entry = entries[gestureID] else { return }
        entry.startRequestID = requestID
        entries[gestureID] = entry
        gestureByRequestID[requestID] = gestureID
    }

    public mutating func expectRelease(gestureID: String) {
        guard var entry = entries[gestureID] else { return }
        entry.releaseQueued = true
        entries[gestureID] = entry
    }

    public mutating func registerRelease(gestureID: String, requestID: String) {
        guard var entry = entries[gestureID] else { return }
        entry.releaseQueued = true
        entry.releaseRequestID = requestID
        entries[gestureID] = entry
        gestureByRequestID[requestID] = gestureID
    }

    public mutating func cancel(gestureID: String) {
        guard let entry = entries.removeValue(forKey: gestureID) else { return }
        if let requestID = entry.startRequestID {
            gestureByRequestID.removeValue(forKey: requestID)
        }
        if let requestID = entry.releaseRequestID {
            gestureByRequestID.removeValue(forKey: requestID)
        }
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        gestureByRequestID.removeAll(keepingCapacity: true)
    }

    public mutating func acceptResult(requestID: String, succeeded: Bool) -> Outcome? {
        guard let gestureID = gestureByRequestID[requestID], var entry = entries[gestureID] else {
            return nil
        }

        if entry.startRequestID == requestID {
            entry.startSucceeded = succeeded
            if succeeded {
                if let releaseSucceeded = entry.releaseSucceeded {
                    remove(gestureID: gestureID, entry: entry)
                    return releaseSucceeded
                        ? .releaseAccepted(gestureID: gestureID)
                        : .releaseFailureRequiresSessionTeardown(gestureID: gestureID)
                }
                entries[gestureID] = entry
                return .startAccepted(gestureID: gestureID)
            }
            if let releaseSucceeded = entry.releaseSucceeded {
                remove(gestureID: gestureID, entry: entry)
                return releaseSucceeded
                    ? .startRejected(gestureID: gestureID)
                    : .releaseFailureSuppressed(gestureID: gestureID)
            }
            if !entry.releaseQueued {
                remove(gestureID: gestureID, entry: entry)
            } else {
                entries[gestureID] = entry
            }
            return .startRejected(gestureID: gestureID)
        }

        guard entry.releaseRequestID == requestID else { return nil }
        entry.releaseSucceeded = succeeded
        guard let startSucceeded = entry.startSucceeded else {
            entries[gestureID] = entry
            return succeeded
                ? .releaseResultDeferred(gestureID: gestureID)
                : .releaseFailureDeferred(gestureID: gestureID)
        }

        remove(gestureID: gestureID, entry: entry)
        if !succeeded, startSucceeded {
            return .releaseFailureRequiresSessionTeardown(gestureID: gestureID)
        }
        if !succeeded {
            return .releaseFailureSuppressed(gestureID: gestureID)
        }
        return .releaseAccepted(gestureID: gestureID)
    }

    private mutating func remove(gestureID: String, entry: Entry) {
        entries.removeValue(forKey: gestureID)
        if let requestID = entry.startRequestID {
            gestureByRequestID.removeValue(forKey: requestID)
        }
        if let requestID = entry.releaseRequestID {
            gestureByRequestID.removeValue(forKey: requestID)
        }
    }
}
