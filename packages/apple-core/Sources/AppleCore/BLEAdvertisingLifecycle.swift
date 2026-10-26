public struct BLEAdvertisingLifecycle: Equatable {
    public enum Phase: Equatable {
        case idle
        case starting
        case advertising
        case failed
    }

    public enum StartResult: Equatable {
        case ignored
        case started
        case retry
        case failed
    }

    public private(set) var phase = Phase.idle
    private var attempts = 0
    private let maximumAttempts = 2

    public init() {}

    public mutating func beginStart() -> Bool {
        guard phase == .idle, attempts < maximumAttempts else { return false }
        phase = .starting
        attempts += 1
        return true
    }

    public mutating func completeStart(successfully: Bool) -> StartResult {
        guard phase == .starting else { return .ignored }
        if successfully {
            phase = .advertising
            attempts = 0
            return .started
        }

        guard attempts < maximumAttempts else {
            phase = .failed
            return .failed
        }
        phase = .idle
        return .retry
    }

    public mutating func reset() {
        phase = .idle
        attempts = 0
    }
}
