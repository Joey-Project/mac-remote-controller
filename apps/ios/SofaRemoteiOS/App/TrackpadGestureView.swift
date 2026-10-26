import AppleCore
import UIKit

/// Classifies complete touch sequences so a changing finger count can never become a tap.
final class TrackpadView: UIView {
    var enabled = true { didSet { if !enabled { cancelSequence() } } }
    var dragEnabled = true
    var shortcutsEnabled = true
    var forceClickEnabled = true
    var hapticsEnabled = false
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onTap: ((TimeInterval) -> Void)?
    var onRightClick: ((TimeInterval) -> Void)?
    var onDragBegin: (() -> UUID?)?
    var onDragMove: ((UUID, Double, Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var onShortcut: ((SystemShortcut) -> Void)?

    private enum Mode { case idle, pending, move, scroll, drag, swipe, blocked }
    private var mode: Mode = .idle
    private var sequence = TouchSequencePolicy()
    private var touchCount = 0
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var didForceClick = false
    private var fingerMovement = TouchFingerMovementTracker<ObjectIdentifier>()
    private var dragHeld = false
    private var activeDragID: UUID?
    private var dragSequence = PointerDragSequencePolicy()
    private var lastRejectedDragID: UUID?
    private let threshold: CGFloat = 7
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let pressureFeedback = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        let before = touchCount
        touchCount += touches.count
        if before == 0 {
            _ = sequence.begin(adding: touches.count, at: monotonicTime)
            mode = .pending
            start = centroid(event) ?? touches.first?.location(in: self) ?? .zero
            previous = start; didForceClick = false
            fingerMovement.reset()
            rememberTouchOrigins(touches)
            if hapticsEnabled { tapFeedback.prepare(); pressureFeedback.prepare() }
        } else {
            guard mode != .blocked else { return }
            let outcome = sequence.begin(
                adding: touches.count, at: monotonicTime,
                allowsShortcutPromotion: shortcutsEnabled)
            switch outcome {
            case .joined, .promotedToShortcut:
                if outcome == .promotedToShortcut {
                    if dragHeld { dragHeld = false; onDragEnd?() }
                    activeDragID = nil
                    dragSequence.finish()
                    mode = .pending
                }
                let point = centroid(event) ?? previous
                start = point; previous = point
                rememberTouchOrigins(touches)
                updateTwoFingerTapSlop(event, including: touches)
            case .cancelled:
                cancelSequence(blockUntilLift: true)
            default: break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, mode != .blocked, mode != .idle else { return }
        if sequence.cancelsMovementAfterTouchCountChange(currentTouchCount: touchCount) {
            cancelSequence(blockUntilLift: true); return
        }
        updateTwoFingerTapSlop(event, including: touches)
        if sequence.hasPartialPendingLift {
            // A pending two-finger tap remains pending while the final finger
            // is down. Observe its movement for tap slop without converting it
            // into a one-finger pointer/scroll gesture.
            return
        }
        let point = centroid(event) ?? touches.first?.location(in: self) ?? previous
        var delta = CGPoint(x: point.x - previous.x, y: point.y - previous.y)
        let total = hypot(point.x - start.x, point.y - start.y)
        if mode == .pending,
            TouchGesturePolicy.shouldBeginMovement(
                distance: Double(total), threshold: Double(threshold))
        {
            activateGesture()
            delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        }
        emitMovement(delta, total: CGPoint(x: point.x - start.x, y: point.y - start.y))
        previous = point
        checkForceClick(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateTwoFingerTapSlop(event, including: touches)
        let wasSwipe = mode == .swipe
        let completedCount = sequence.initialCount
        let endOutcome = sequence.end(
            removing: touches.count, dragEnabled: dragEnabled,
            shortcutsEnabled: shortcutsEnabled, at: monotonicTime)
        if wasSwipe, endOutcome == .cancelled,
            let action = shortcut(from: CGPoint(x: previous.x - start.x, y: previous.y - start.y))
        {
            onShortcut?(action)
            emitHaptic()
        }
        touchCount = max(0, touchCount - touches.count)
        if endOutcome == .partialPendingLift { return }
        if endOutcome == .cancelled {
            if dragHeld { dragHeld = false; onDragEnd?() }
            mode = touchCount > 0 ? .blocked : .idle
            if touchCount == 0 { finishSequence() }
            return
        }
        guard touchCount == 0 else { return }
        if enabled, !didForceClick {
            if case .ended(let kind, let tapAllowed) = endOutcome, mode == .pending,
                tapAllowed
            {
                let tapTimestamp = touches.map(\.timestamp).max() ?? monotonicTime
                if kind == .pointer, completedCount == 1 {
                    onTap?(tapTimestamp)
                    emitHaptic()
                }
                if TouchGesturePolicy.shouldEmitTwoFingerRightClick(
                    completedCount: completedCount, kind: kind, tapAllowed: tapAllowed,
                    perFingerDisplacements: fingerMovement.displacements,
                    threshold: Double(threshold))
                {
                    onRightClick?(tapTimestamp)
                    emitHaptic()
                }
            }
        }
        finishSequence()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchCount = max(0, touchCount - touches.count)
        sequence.cancel()
        cancelSequence(blockUntilLift: touchCount > 0)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow(); if window == nil { cancelSequence() }
    }

    private func rememberTouchOrigins(_ touches: Set<UITouch>) {
        for touch in touches where touch.view === self {
            let location = touch.location(in: self)
            fingerMovement.begin(
                id: ObjectIdentifier(touch), x: Double(location.x), y: Double(location.y))
        }
    }

    private func updateTwoFingerTapSlop(_ event: UIEvent?, including touches: Set<UITouch>) {
        guard sequence.initialCount == 2, mode == .pending else { return }
        var observedTouches = event?.allTouches?.filter { $0.view === self } ?? []
        observedTouches.append(contentsOf: touches)
        for touch in observedTouches {
            let location = touch.location(in: self)
            fingerMovement.record(
                id: ObjectIdentifier(touch), x: Double(location.x), y: Double(location.y))
        }
    }

    private var monotonicTime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func centroid(_ event: UIEvent?) -> CGPoint? {
        let points =
            event?.allTouches?.filter { $0.view === self }.map { $0.location(in: self) } ?? []
        guard !points.isEmpty else { return nil }
        return CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private func shortcut(from delta: CGPoint) -> SystemShortcut? {
        TouchGesturePolicy.shortcut(deltaX: Double(delta.x), deltaY: Double(delta.y))
    }

    private func cancelSequence(blockUntilLift: Bool = false) {
        if dragHeld {
            dragHeld = false
            onDragEnd?()
        }
        activeDragID = nil
        if blockUntilLift { dragSequence.blockUntilLift() } else { dragSequence.finish() }
        sequence.cancel()
        fingerMovement.reset()
        mode = blockUntilLift ? .blocked : .idle
        if !blockUntilLift { touchCount = 0 }
    }
    func cancelTouches() {
        cancelSequence()
        touchCount = 0
    }

    func rejectDragStart(_ dragID: UUID?) {
        guard let dragID, dragID != lastRejectedDragID else { return }
        lastRejectedDragID = dragID
        guard activeDragID == dragID,
            dragSequence.reject(gestureID: dragID.uuidString)
        else { return }
        activeDragID = nil
        dragHeld = false
        mode = .blocked
    }

    private func finishSequence() {
        if dragHeld {
            dragHeld = false
            onDragEnd?()
        }
        activeDragID = nil
        dragSequence.finish()
        sequence.cancel()
        fingerMovement.reset()
        mode = .idle
        touchCount = 0
    }
}

extension TrackpadView {
    private func activateGesture() {
        switch TouchGesturePolicy.kind(
            touchCount: sequence.initialCount, dragEnabled: dragEnabled,
            shortcutsEnabled: shortcutsEnabled
        ) {
        case .pointer: mode = .move
        case .scroll: mode = .scroll
        case .drag:
            let dragID = onDragBegin?()
            if dragSequence.begin(gestureID: dragID?.uuidString) {
                activeDragID = dragID
                mode = .drag
                dragHeld = true
                emitHaptic()
            } else {
                activeDragID = nil
                mode = .blocked
                dragHeld = false
            }
        case .shortcutSwipe: mode = .swipe
        case .ignore: mode = .blocked
        }
        sequence.activate()
    }

    private func emitMovement(_ delta: CGPoint, total: CGPoint) {
        switch mode {
        case .move:
            onMove?(
                Double(delta.x.clamped(to: -500...500)), Double(delta.y.clamped(to: -500...500)))
        case .scroll:
            onScroll?(
                Double(delta.x.clamped(to: -100...100)), Double(delta.y.clamped(to: -100...100)))
        case .drag:
            guard let activeDragID,
                dragSequence.canSendMovement(gestureID: activeDragID.uuidString)
            else { return }
            onDragMove?(
                activeDragID,
                Double(delta.x.clamped(to: -500...500)),
                Double(delta.y.clamped(to: -500...500)))
        case .swipe:
            if let action = shortcut(from: total) {
                onShortcut?(action)
                emitHaptic()
                mode = .blocked
            }
        default: break
        }
    }

    private func checkForceClick(_ touches: Set<UITouch>) {
        if sequence.initialCount == 1, !didForceClick, forceClickEnabled,
            traitCollection.forceTouchCapability == .available,
            let touch = touches.first, touch.maximumPossibleForce > 0,
            touch.force / touch.maximumPossibleForce >= 0.78
        {
            didForceClick = true
            mode = .blocked
            onTap?(touch.timestamp)
            emitHaptic(pressure: true)
        }
    }

    private func emitHaptic(pressure: Bool = false) {
        guard hapticsEnabled else { return }
        (pressure ? pressureFeedback : tapFeedback).impactOccurred()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
