import Foundation

/// Includes system sleep, so a suspended Mac cannot preserve an expired PIN.
public enum NumericPairingClock {
    private static let origin = ContinuousClock.now

    public static func now() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// A code is single-use and cannot regain its attempt budget after a retry.
public struct NumericPairingAttemptBudget: Sendable {
    public private(set) var remainingAttempts = 3
    private let deadline: TimeInterval
    private var consumed = false

    public init(startedAt: TimeInterval) { deadline = startedAt + 120 }

    public func isActive(at now: TimeInterval) -> Bool {
        now.isFinite && now >= deadline - 120 && now < deadline
            && !consumed && remainingAttempts > 0
    }

    public func expiresIn(at now: TimeInterval) -> Int {
        guard isActive(at: now) else { return 0 }
        return min(120, max(1, Int(ceil(deadline - now))))
    }

    public mutating func recordFailure(at now: TimeInterval) {
        guard isActive(at: now) else { return }
        remainingAttempts -= 1
    }

    public mutating func consume(at now: TimeInterval) -> Bool {
        guard isActive(at: now) else { return false }
        consumed = true
        return true
    }
}

/// Global rolling limits survive connection cancellation and replacement codes.
public struct NumericPairingRequestLimiter: Sendable {
    private var requests: [TimeInterval] = []
    private var failures: [TimeInterval] = []
    private var lastTime: TimeInterval = 0

    public init() {}

    public mutating func mayAttempt(at now: TimeInterval) -> Bool {
        guard advance(to: now) else { return false }
        return failures.count < 3
    }

    public mutating func admitRequest(at now: TimeInterval) -> Bool {
        guard advance(to: now), requests.count < 3, failures.count < 3 else { return false }
        requests.append(now)
        return true
    }

    public mutating func recordFailure(at now: TimeInterval) {
        guard advance(to: now) else { return }
        if failures.count < 3 { failures.append(now) }
    }

    private mutating func advance(to now: TimeInterval) -> Bool {
        guard now.isFinite, now >= lastTime else { return false }
        lastTime = now
        requests.removeAll { now - $0 >= 60 }
        failures.removeAll { now - $0 >= 60 }
        return true
    }
}
