import AppleCore
import SwiftUI
import UIKit

struct TouchpadCard: View {
    let isEnabled: Bool
    let dragEnabled: Bool
    let shortcutsEnabled: Bool
    let forceClickEnabled: Bool
    let hapticsEnabled: Bool
    let rejectedDragID: UUID?
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: (TimeInterval) -> Void
    let onRightClick: (TimeInterval) -> Void
    let onDragBegin: () -> UUID?
    let onDragMove: (UUID, Double, Double) -> Void
    let onDragEnd: () -> Void
    let onShortcut: (SystemShortcut) -> Void

    private var gestureInstructions: TouchGestureInstructions {
        TouchGesturePolicy.instructions(
            dragEnabled: dragEnabled, shortcutsEnabled: shortcutsEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Touchpad", systemImage: "cursorarrow")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(gestureInstructions.caption)
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
                    rejectedDragID: rejectedDragID,
                    onMove: onMove, onScroll: onScroll, onTap: onTap,
                    onRightClick: onRightClick, onDragBegin: onDragBegin, onDragMove: onDragMove,
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
            .accessibilityHint(gestureInstructions.accessibilityHint)
            .accessibilityAction(named: Text("Right-click")) {
                if isEnabled { onRightClick(ProcessInfo.processInfo.systemUptime) }
            }
            .accessibilityAction(.default) {
                if isEnabled { onTap(ProcessInfo.processInfo.systemUptime) }
            }
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
    let rejectedDragID: UUID?
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: (TimeInterval) -> Void
    let onRightClick: (TimeInterval) -> Void
    let onDragBegin: () -> UUID?
    let onDragMove: (UUID, Double, Double) -> Void
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
        view.onDragMove = onDragMove
        view.rejectDragStart(rejectedDragID)
        view.onDragEnd = onDragEnd; view.onShortcut = onShortcut
    }
}
