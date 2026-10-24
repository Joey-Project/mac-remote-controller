import AppleCore
import SwiftUI
import UIKit

struct TouchpadCard: View {
    let isEnabled: Bool
    let dragEnabled: Bool
    let shortcutsEnabled: Bool
    let forceClickEnabled: Bool
    let hapticsEnabled: Bool
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightClick: () -> Void
    let onDragBegin: () -> Void
    let onDragEnd: () -> Void
    let onShortcut: (SystemShortcut) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Touchpad", systemImage: "cursorarrow")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("1 finger move/tap · 2 fingers scroll/right-click · 3 drag · 4 swipe")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(
                    Color(uiColor: .tertiarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 16).strokeBorder(
                    .primary.opacity(0.08), lineWidth: 1)
                TrackpadSurface(
                    enabled: isEnabled, dragEnabled: dragEnabled,
                    shortcutsEnabled: shortcutsEnabled, forceClickEnabled: forceClickEnabled,
                    hapticsEnabled: hapticsEnabled,
                    onMove: onMove, onScroll: onScroll, onTap: onTap,
                    onRightClick: onRightClick, onDragBegin: onDragBegin,
                    onDragEnd: onDragEnd, onShortcut: onShortcut
                ).clipShape(RoundedRectangle(cornerRadius: 16))
                if !isEnabled {
                    Image(systemName: "hand.tap").font(.system(size: 34))
                        .foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touchpad")
            .accessibilityIdentifier("touchpad.surface")
            .accessibilityHint(
                "One finger moves and taps; two fingers scroll or right-click; "
                    + "three fingers drag; four fingers open Mac window controls"
            )
            .accessibilityAction(named: Text("Right-click")) { if isEnabled { onRightClick() } }
            .accessibilityAction(.default) { if isEnabled { onTap() } }
            .disabled(!isEnabled)
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TrackpadSurface: UIViewRepresentable {
    let enabled: Bool
    let dragEnabled: Bool
    let shortcutsEnabled: Bool
    let forceClickEnabled: Bool
    let hapticsEnabled: Bool
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightClick: () -> Void
    let onDragBegin: () -> Void
    let onDragEnd: () -> Void
    let onShortcut: (SystemShortcut) -> Void

    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView(); update(view); return view
    }
    func updateUIView(_ uiView: TrackpadView, context: Context) { update(uiView) }
    static func dismantleUIView(_ uiView: TrackpadView, coordinator: ()) { uiView.cancelTouches() }
    private func update(_ view: TrackpadView) {
        view.enabled = enabled; view.dragEnabled = dragEnabled
        view.shortcutsEnabled = shortcutsEnabled; view.forceClickEnabled = forceClickEnabled
        view.hapticsEnabled = hapticsEnabled
        view.onMove = onMove; view.onScroll = onScroll; view.onTap = onTap
        view.onRightClick = onRightClick; view.onDragBegin = onDragBegin
        view.onDragEnd = onDragEnd; view.onShortcut = onShortcut
    }
}

/// Classifies complete touch sequences so a changing finger count can never become a tap.
private final class TrackpadView: UIView {
    var enabled = true { didSet { if !enabled { cancelSequence() } } }
    var dragEnabled = true
    var shortcutsEnabled = true
    var forceClickEnabled = true
    var hapticsEnabled = false
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onTap: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragBegin: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onShortcut: ((SystemShortcut) -> Void)?

    private enum Mode { case idle, pending, move, scroll, drag, swipe, blocked }
    private var mode: Mode = .idle
    private var sequence = TouchSequencePolicy()
    private var touchCount = 0
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var didForceClick = false
    private var dragHeld = false
    private let threshold: CGFloat = 7

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true }
    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled else { return }
        let before = touchCount
        touchCount += touches.count
        if before == 0 {
            _ = sequence.begin(adding: touches.count)
            mode = .pending
            start = centroid(event) ?? touches.first?.location(in: self) ?? .zero
            previous = start; didForceClick = false
        } else {
            guard mode != .blocked else { return }
            switch sequence.begin(adding: touches.count) {
            case .joined:
                let point = centroid(event) ?? previous
                start = point; previous = point
            case .cancelled:
                cancelSequence(blockUntilLift: true)
            default: break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard enabled, mode != .blocked, mode != .idle else { return }
        if touchCount != sequence.initialCount { cancelSequence(blockUntilLift: true); return }
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
        emitMovement(delta)
        previous = point
        checkForceClick(touches)
    }

    private func activateGesture() {
        switch TouchGesturePolicy.kind(
            touchCount: sequence.initialCount, dragEnabled: dragEnabled,
            shortcutsEnabled: shortcutsEnabled
        ) {
        case .pointer: mode = .move
        case .scroll: mode = .scroll
        case .drag:
            mode = .drag
            dragHeld = true
            onDragBegin?()
        case .shortcutSwipe: mode = .swipe
        case .ignore: mode = .blocked
        }
        sequence.activate()
    }

    private func emitMovement(_ delta: CGPoint) {
        switch mode {
        case .move:
            onMove?(
                Double(delta.x.clamped(to: -500...500)), Double(delta.y.clamped(to: -500...500)))
        case .scroll:
            onScroll?(
                Double(delta.x.clamped(to: -100...100)), Double(delta.y.clamped(to: -100...100)))
        case .drag:
            onMove?(
                Double(delta.x.clamped(to: -500...500)), Double(delta.y.clamped(to: -500...500)))
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
            onTap?()
            if hapticsEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasSwipe = mode == .swipe
        let completedCount = sequence.initialCount
        let endOutcome = sequence.end(
            removing: touches.count, dragEnabled: dragEnabled,
            shortcutsEnabled: shortcutsEnabled)
        if wasSwipe, endOutcome == .cancelled,
            let action = shortcut(from: CGPoint(x: previous.x - start.x, y: previous.y - start.y))
        {
            onShortcut?(action)
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
            if case .ended(let kind) = endOutcome, mode == .pending {
                if kind == .pointer, completedCount == 1 { onTap?() }
                if kind == .scroll, completedCount == 2 { onRightClick?() }
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
        sequence.cancel()
        mode = blockUntilLift ? .blocked : .idle
        if !blockUntilLift { touchCount = 0 }
    }
    func cancelTouches() {
        cancelSequence()
        touchCount = 0
    }
    private func finishSequence() {
        if dragHeld {
            dragHeld = false
            onDragEnd?()
        }
        sequence.cancel()
        mode = .idle
        touchCount = 0
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
