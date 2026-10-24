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
    public static func shouldBeginMovement(distance: Double, threshold: Double) -> Bool {
        distance.isFinite && threshold.isFinite && threshold >= 0 && distance >= threshold
    }

    public static func isTwoFingerTapWithinSlop(
        perFingerDisplacements: [Double], threshold: Double
    ) -> Bool {
        perFingerDisplacements.count == 2 && threshold.isFinite && threshold > 0
            && perFingerDisplacements.allSatisfy { $0.isFinite && $0 >= 0 && $0 < threshold }
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

public enum TouchSequenceOutcome: Sendable, Equatable {
    case started
    case joined
    case cancelled
    case partialPendingLift
    case ended(TouchGestureKind)
    case ignored
}

/// Tracks a whole physical touch sequence independently of UIKit event batching.
public struct TouchSequencePolicy: Sendable, Equatable {
    public private(set) var touchCount = 0
    public private(set) var initialCount = 0
    public private(set) var isPending = false
    public private(set) var isActive = false

    public init() {}

    public mutating func begin(adding count: Int) -> TouchSequenceOutcome {
        guard count > 0 else { return .ignored }
        if touchCount == 0 {
            touchCount = count; initialCount = count; isPending = true; isActive = false
            return .started
        }
        touchCount += count
        if isPending { initialCount = touchCount; return .joined }
        if isActive { isActive = false; isPending = false; return .cancelled }
        return .ignored
    }

    public mutating func activate() {
        guard isPending else { return }
        isPending = false; isActive = true
    }

    public mutating func end(removing count: Int, dragEnabled: Bool, shortcutsEnabled: Bool)
        -> TouchSequenceOutcome
    {
        guard count > 0, touchCount > 0 else { return .ignored }
        let wasPending = isPending
        let wasActive = isActive
        touchCount = max(0, touchCount - count)
        if wasActive {
            isActive = false; isPending = false
            if touchCount == 0 { initialCount = 0 }
            return .cancelled
        }
        if wasPending, touchCount > 0 { return .partialPendingLift }
        if wasPending {
            let ended = TouchGesturePolicy.kind(
                touchCount: initialCount, dragEnabled: dragEnabled,
                shortcutsEnabled: shortcutsEnabled)
            initialCount = 0; isPending = false
            return .ended(ended)
        }
        if touchCount == 0 { initialCount = 0 }
        return .ignored
    }

    public mutating func cancel() {
        touchCount = 0; initialCount = 0; isPending = false; isActive = false
    }
}
