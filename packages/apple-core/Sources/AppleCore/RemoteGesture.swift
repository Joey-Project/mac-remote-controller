import Foundation

public enum RemoteGestureKind: String, Codable, Sendable, Equatable {
    case magnify
    case horizontalSwipe
    case verticalSwipe
}

public enum RemoteGesturePhase: String, Codable, Sendable, Equatable {
    case began
    case changed
    case ended
    case cancelled

    public var isTerminal: Bool { self == .ended || self == .cancelled }
}

/// Cumulative values survive coalescing: log(scale) for magnify, normalized
/// travel for Dock swipes. Timestamps belong to the sending client's uptime.
public struct RemoteGestureFrame: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: RemoteGestureKind
    public let phase: RemoteGesturePhase
    public let value: Double
    public let timestamp: TimeInterval

    public init(
        id: UUID, kind: RemoteGestureKind, phase: RemoteGesturePhase,
        value: Double, timestamp: TimeInterval
    ) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.value = value
        self.timestamp = timestamp
    }

    public func validate() throws {
        let limit = kind == .magnify ? 4.0 : 1.0
        guard value.isFinite, abs(value) <= limit,
            timestamp.isFinite, (0...WireLimits.maximumTapTimestampSeconds).contains(timestamp),
            phase != .began || value == 0
        else { throw WireProtocolError.invalidCommand("Invalid phased gesture value or timestamp") }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, phase, value, timestamp
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: MediaDynamicCodingKey.self)
        guard Set(fields.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue))
        else { throw WireProtocolError.invalidCommand("Unexpected gesture fields") }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(RemoteGestureKind.self, forKey: .kind)
        phase = try container.decode(RemoteGesturePhase.self, forKey: .phase)
        value = try container.decode(Double.self, forKey: .value)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        try validate()
    }
}

/// Locks a two-finger sequence to pan or pinch once movement is unambiguous.
public struct TwoFingerGesturePolicy: Sendable {
    public enum Kind: Sendable, Equatable { case pending, scroll, magnify }
    public private(set) var kind: Kind = .pending
    private var initialSpan: Double = 0

    public init() {}

    public mutating func begin(span: Double) {
        initialSpan = span.isFinite ? max(0, span) : 0
        kind = .pending
    }

    public mutating func update(span: Double, translationX: Double, translationY: Double) -> Kind {
        guard kind == .pending, span.isFinite, span >= 0,
            translationX.isFinite, translationY.isFinite
        else { return kind }
        let pan = hypot(translationX, translationY)
        let separation = abs(span - initialSpan)
        if max(initialSpan, span) >= 8, separation >= 7, separation > pan * 1.25 {
            kind = .magnify
        } else if pan >= 7, pan > separation * 0.8 {
            kind = .scroll
        }
        return kind
    }

    public func magnification(span: Double) -> Double {
        guard span.isFinite else { return 0 }
        return min(4, max(-4, log(max(8, span) / max(8, initialSpan))))
    }
}

public enum FourFingerGesturePolicy {
    public static func kind(x: Double, y: Double) -> RemoteGestureKind {
        abs(x) > abs(y) ? .horizontalSwipe : .verticalSwipe
    }

    public static func progress(kind: RemoteGestureKind, x: Double, y: Double) -> Double {
        let distance = kind == .horizontalSwipe ? x : -y
        return min(1, max(-1, distance / 220))
    }
}

/// Includes final touch locations in the terminal value without another update frame.
public enum RemoteGestureReleasePolicy {
    public static func value(
        kind: RemoteGestureKind, positions: [SIMD2<Double>], start: SIMD2<Double>,
        pinch: TwoFingerGesturePolicy
    ) -> Double? {
        guard positions.count == (kind == .magnify ? 2 : 4),
            positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }
        if kind == .magnify {
            let span = hypot(positions[1].x - positions[0].x, positions[1].y - positions[0].y)
            guard span.isFinite else { return nil }
            return pinch.magnification(span: span)
        }
        let displacement = positions.reduce(SIMD2<Double>.zero, +) / Double(positions.count) - start
        guard displacement.x.isFinite, displacement.y.isFinite else { return nil }
        return FourFingerGesturePolicy.progress(kind: kind, x: displacement.x, y: displacement.y)
    }
}
