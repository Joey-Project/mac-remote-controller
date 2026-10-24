import Foundation

/// Keeps the player-volume thumb aligned with accepted requests while adapter snapshots catch up.
public struct PlayerVolumeDisplayState: Sendable, Equatable {
    private(set) public var targetID: String?
    private(set) public var maximum: Double?
    private(set) public var remoteValue: Double?
    private var requestedValues: [RequestedValue] = []
    private var confirmedValue: Double?

    private struct RequestedValue: Sendable, Equatable {
        let requestID: String
        let value: Double
    }

    public init(targetID: String? = nil, maximum: Double? = nil, remoteValue: Double? = nil) {
        self.targetID = targetID
        self.maximum = maximum
        self.remoteValue = remoteValue
    }

    public var displayedValue: Double? {
        requestedValues.last?.value ?? confirmedValue ?? remoteValue
    }

    public mutating func configure(
        targetID: String?, maximum: Double?, remoteValue: Double?, isConnected: Bool
    ) {
        guard isConnected, let targetID, let maximum, maximum.isFinite, maximum > 0 else {
            reset(targetID: targetID, maximum: maximum, remoteValue: nil)
            return
        }
        guard self.targetID == targetID, self.maximum == maximum else {
            reset(
                targetID: targetID, maximum: maximum,
                remoteValue: valid(remoteValue, maximum: maximum))
            return
        }
        guard let value = valid(remoteValue, maximum: maximum) else { return }
        let previousRemoteValue = self.remoteValue
        self.remoteValue = value
        if let matchingIndex = requestedValues.firstIndex(where: { $0.value == value }) {
            requestedValues.removeFirst(matchingIndex + 1)
            confirmedValue = nil
        } else if previousRemoteValue != value {
            requestedValues.removeAll(keepingCapacity: true)
            confirmedValue = nil
        } else if confirmedValue == value {
            confirmedValue = nil
        }
    }

    public mutating func request(
        id requestID: String, value: Double, wasAccepted: Bool
    ) {
        guard wasAccepted, !requestID.isEmpty, let maximum,
            valid(value, maximum: maximum) != nil,
            requestedValues.count < 16
        else { return }
        requestedValues.append(RequestedValue(requestID: requestID, value: value))
    }

    /// Applies a result for the exact target and value tracked by the sender.
    public mutating func complete(
        targetID: String, requestID: String, value: Double, succeeded: Bool
    ) {
        guard self.targetID == targetID, let maximum,
            valid(value, maximum: maximum) != nil
        else { return }
        guard
            let index = requestedValues.firstIndex(where: {
                $0.requestID == requestID && $0.value == value
            })
        else { return }
        if succeeded {
            requestedValues.removeFirst(index + 1)
            confirmedValue = value
        } else {
            requestedValues.remove(at: index)
        }
    }

    public mutating func reset(
        targetID: String? = nil, maximum: Double? = nil, remoteValue: Double? = nil
    ) {
        self.targetID = targetID
        self.maximum = maximum
        self.remoteValue = maximum.flatMap { valid(remoteValue, maximum: $0) }
        requestedValues.removeAll(keepingCapacity: true)
        confirmedValue = nil
    }

    private func valid(_ value: Double?, maximum: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maximum else { return nil }
        return value
    }
}
