import Foundation

public struct RTTBenchmarkReport: Equatable, Sendable {
    public let transport: String
    public let groups: Int
    public let samplesPerGroup: Int
    public let warmupCount: Int
    public let successfulRoundTripsNanoseconds: [UInt64]
    public let timeoutCount: Int
    public let cancelled: Bool

    public var measuredAttemptCount: Int { successfulRoundTripsNanoseconds.count + timeoutCount }
    public var expectedAttemptCount: Int { groups * samplesPerGroup }
    public var lossRate: Double {
        guard measuredAttemptCount > 0 else { return 0 }
        return Double(timeoutCount) / Double(measuredAttemptCount)
    }
    public var minimumMilliseconds: Double? { percentile(0) }
    public var medianMilliseconds: Double? { percentile(0.5) }
    public var p95Milliseconds: Double? { percentile(0.95) }
    public var maximumMilliseconds: Double? { percentile(1) }
    public var jitterMilliseconds: Double? {
        guard let p50 = medianMilliseconds, let p95 = p95Milliseconds else { return nil }
        return p95 - p50
    }

    public var summary: String {
        let statistics: String
        if let minimum = minimumMilliseconds, let p50 = medianMilliseconds,
            let p95 = p95Milliseconds, let maximum = maximumMilliseconds,
            let jitter = jitterMilliseconds
        {
            statistics = String(
                format: "min %.2f ms · p50 %.2f ms · p95 %.2f ms · max %.2f ms · jitter %.2f ms",
                minimum, p50, p95, maximum, jitter)
        } else {
            statistics = "No successful probes"
        }
        let status = cancelled ? "Partial · cancelled" : "Complete"
        return "\(transport) · \(status) · \(measuredAttemptCount)/\(expectedAttemptCount) · "
            + "\(statistics) · loss \(timeoutCount) (\(Int(lossRate * 100))%)"
    }

    fileprivate func percentile(_ fraction: Double) -> Double? {
        guard !successfulRoundTripsNanoseconds.isEmpty else { return nil }
        let values = successfulRoundTripsNanoseconds.sorted()
        let index = min(
            values.count - 1, Int(ceil(fraction * Double(values.count))) - (fraction == 0 ? 0 : 1))
        return Double(values[index]) / 1_000_000
    }
}

public struct RTTBenchmarkRequestTracker: Sendable {
    public struct Key: Equatable, Hashable, Sendable {
        public let id: String
        public let sequence: UInt64

        public init(id: String, sequence: UInt64) {
            self.id = id
            self.sequence = sequence
        }
    }

    public enum PongDisposition: Equatable, Sendable {
        case active
        case retired
        case unexpected
    }

    public static let defaultRetiredCapacity = 128

    private let retiredCapacity: Int
    private var active: Key?
    private var retired: Set<Key> = []

    public init(retiredCapacity: Int = Self.defaultRetiredCapacity) {
        self.retiredCapacity = max(0, retiredCapacity)
    }

    public var canBegin: Bool { active == nil && retired.count < retiredCapacity }
    public var retiredCount: Int { retired.count }

    @discardableResult
    public mutating func begin(id: String, sequence: UInt64) -> Bool {
        let key = Key(id: id, sequence: sequence)
        guard canBegin, !retired.contains(key) else { return false }
        active = key
        return true
    }

    @discardableResult
    public mutating func retireActive() -> Bool {
        guard let key = active else { return true }
        guard retired.count < retiredCapacity else { return false }
        active = nil
        retired.insert(key)
        return true
    }

    public mutating func consumePong(id: String, sequence: UInt64) -> PongDisposition {
        let key = Key(id: id, sequence: sequence)
        if active == key {
            active = nil
            return .active
        }
        if retired.remove(key) != nil { return .retired }
        return .unexpected
    }

    public mutating func reset() {
        active = nil
        retired.removeAll()
    }
}

/// Sequential benchmark accumulator; callers send one probe at a time.
public struct RTTBenchmarkAccumulator: Sendable {
    public static let maximumGroups = 5
    public static let maximumSamplesPerGroup = 100
    public static let maximumWarmupCount = 5
    public let transport: String
    public let groups: Int
    public let samplesPerGroup: Int
    public let warmupCount: Int
    private var warmupsRemaining: Int
    private var measuredAttempts = 0
    private var samples: [UInt64] = []
    private var timeouts = 0
    private var cancelled = false

    public init(
        transport: String, groups: Int = 3, samplesPerGroup: Int = 30, warmupCount: Int = 3
    ) {
        self.transport = transport
        self.groups = min(Self.maximumGroups, max(1, groups))
        self.samplesPerGroup = min(Self.maximumSamplesPerGroup, max(1, samplesPerGroup))
        self.warmupCount = min(Self.maximumWarmupCount, max(0, warmupCount))
        warmupsRemaining = min(Self.maximumWarmupCount, max(0, warmupCount))
    }

    public var isComplete: Bool { measuredAttempts >= groups * samplesPerGroup || cancelled }
    public var progress: Int { min(measuredAttempts, groups * samplesPerGroup) }
    public var currentGroup: Int { min(groups, progress / samplesPerGroup + 1) }
    public var currentSampleInGroup: Int { min(samplesPerGroup, progress % samplesPerGroup + 1) }

    public mutating func record(roundTripNanoseconds: UInt64?) {
        guard !isComplete else { return }
        if warmupsRemaining > 0 {
            warmupsRemaining -= 1
            return
        }
        measuredAttempts += 1
        if let roundTripNanoseconds { samples.append(roundTripNanoseconds) } else { timeouts += 1 }
    }

    public mutating func cancel() { cancelled = true }

    public func report() -> RTTBenchmarkReport {
        RTTBenchmarkReport(
            transport: transport, groups: groups, samplesPerGroup: samplesPerGroup,
            warmupCount: warmupCount, successfulRoundTripsNanoseconds: samples,
            timeoutCount: timeouts, cancelled: cancelled)
    }
}
