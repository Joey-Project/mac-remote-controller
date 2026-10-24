import Foundation

public enum TouchGestureKind: Sendable, Equatable {
    case pointer
    case scroll
    case drag
    case shortcutSwipe
    case ignore
}

/// Pure touch-count and swipe policy shared with the UIKit classifier.
public enum TouchGesturePolicy {
    public static let defaultMaximumTapDuration: TimeInterval = 0.5

    public static func shouldBeginMovement(distance: Double, threshold: Double) -> Bool {
        distance.isFinite && threshold.isFinite && threshold >= 0 && distance >= threshold
    }

    public static func isTwoFingerTapWithinSlop(
        perFingerDisplacements: [Double], threshold: Double
    ) -> Bool {
        perFingerDisplacements.count == 2 && threshold.isFinite && threshold > 0
            && perFingerDisplacements.allSatisfy { $0.isFinite && $0 >= 0 && $0 < threshold }
    }

    public static func isTapDurationAllowed(
        startedAt: TimeInterval,
        endedAt: TimeInterval,
        maximumDuration: TimeInterval = defaultMaximumTapDuration
    ) -> Bool {
        startedAt.isFinite && endedAt.isFinite && maximumDuration.isFinite
            && maximumDuration >= 0 && endedAt >= startedAt
            && endedAt - startedAt <= maximumDuration
    }

    public static func kind(
        touchCount: Int, dragEnabled: Bool, shortcutsEnabled: Bool
    ) -> TouchGestureKind {
        switch touchCount {
        case 1: .pointer
        case 2: .scroll
        case 3 where dragEnabled: .drag
        case 4 where shortcutsEnabled: .shortcutSwipe
        default: .ignore
        }
    }

    public static func shortcut(
        deltaX: Double, deltaY: Double, minimumDistance: Double = 40
    ) -> SystemShortcut? {
        guard deltaX.isFinite, deltaY.isFinite, minimumDistance.isFinite,
            minimumDistance >= 0, hypot(deltaX, deltaY) >= minimumDistance
        else { return nil }
        if abs(deltaY) > abs(deltaX) { return deltaY < 0 ? .missionControl : .appExpose }
        return deltaX < 0 ? .previousSpace : .nextSpace
    }
}

/// Keeps maximum per-finger movement for a touch sequence, including fingers
/// whose final `touchesEnded` batch arrives before the rest of the sequence.
public struct TouchFingerMovementTracker<Identifier: Hashable & Sendable>: Sendable {
    private struct Point: Sendable {
        let x: Double
        let y: Double
    }

    private var origins: [Identifier: Point] = [:]
    private var maximumDisplacements: [Identifier: Double] = [:]

    public init() {}

    public var fingerCount: Int { origins.count }
    public var displacements: [Double] { Array(maximumDisplacements.values) }

    public mutating func begin(id: Identifier, x: Double, y: Double) {
        guard x.isFinite, y.isFinite, origins[id] == nil else { return }
        origins[id] = Point(x: x, y: y)
        maximumDisplacements[id] = 0
    }

    public mutating func record(id: Identifier, x: Double, y: Double) {
        guard x.isFinite, y.isFinite, let origin = origins[id] else { return }
        let distance = hypot(x - origin.x, y - origin.y)
        guard distance.isFinite else { return }
        maximumDisplacements[id] = max(maximumDisplacements[id] ?? 0, distance)
    }

    public func staysWithinTwoFingerTapSlop(threshold: Double) -> Bool {
        guard origins.count == 2, maximumDisplacements.count == 2 else { return false }
        return TouchGesturePolicy.isTwoFingerTapWithinSlop(
            perFingerDisplacements: displacements, threshold: threshold)
    }

    public mutating func reset() {
        origins.removeAll(keepingCapacity: true)
        maximumDisplacements.removeAll(keepingCapacity: true)
    }
}

public enum TouchSequenceOutcome: Sendable, Equatable {
    case started
    case joined
    case cancelled
    case partialPendingLift
    case ended(TouchGestureKind, tapAllowed: Bool)
    case ignored
}

/// Tracks a whole physical touch sequence independently of UIKit event batching.
public struct TouchSequencePolicy: Sendable, Equatable {
    public private(set) var touchCount = 0
    public private(set) var initialCount = 0
    public private(set) var isPending = false
    public private(set) var isActive = false
    private var pendingTapStartedAt: TimeInterval?
    private var pendingLiftOccurred = false

    public init() {}

    public mutating func begin(adding count: Int, at time: TimeInterval = 0)
        -> TouchSequenceOutcome
    {
        guard count > 0 else { return .ignored }
        if touchCount == 0 {
            touchCount = count
            initialCount = count
            isPending = true
            isActive = false
            pendingTapStartedAt = time.isFinite ? time : nil
            pendingLiftOccurred = false
            return .started
        }
        touchCount += count
        if isPending, pendingLiftOccurred {
            isPending = false
            return .cancelled
        }
        if isPending { initialCount = touchCount; return .joined }
        if isActive { isActive = false; isPending = false; return .cancelled }
        return .ignored
    }

    public mutating func activate() {
        guard isPending else { return }
        isPending = false; isActive = true
    }

    public mutating func end(
        removing count: Int,
        dragEnabled: Bool,
        shortcutsEnabled: Bool,
        at time: TimeInterval = 0
    ) -> TouchSequenceOutcome {
        guard count > 0, touchCount > 0 else { return .ignored }
        let wasPending = isPending
        let wasActive = isActive
        touchCount = max(0, touchCount - count)
        if wasActive {
            isActive = false; isPending = false
            if touchCount == 0 { initialCount = 0 }
            return .cancelled
        }
        if wasPending, touchCount > 0 {
            pendingLiftOccurred = true
            return .partialPendingLift
        }
        if wasPending {
            let ended = TouchGesturePolicy.kind(
                touchCount: initialCount, dragEnabled: dragEnabled,
                shortcutsEnabled: shortcutsEnabled)
            let tapAllowed =
                pendingTapStartedAt.map {
                    TouchGesturePolicy.isTapDurationAllowed(startedAt: $0, endedAt: time)
                } ?? false
            initialCount = 0
            isPending = false
            pendingLiftOccurred = false
            pendingTapStartedAt = nil
            return .ended(ended, tapAllowed: tapAllowed)
        }
        if touchCount == 0 { initialCount = 0 }
        return .ignored
    }

    public mutating func cancel() {
        touchCount = 0
        initialCount = 0
        isPending = false
        isActive = false
        pendingLiftOccurred = false
        pendingTapStartedAt = nil
    }
}
