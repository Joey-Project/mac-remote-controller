import SwiftUI
import UIKit

struct TouchpadCard: View {
    let isEnabled: Bool
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightClick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Touchpad", systemImage: "cursorarrow")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Move · tap · two-finger scroll or tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                TrackpadSurface(
                    enabled: isEnabled,
                    onMove: onMove,
                    onScroll: onScroll,
                    onTap: onTap,
                    onRightClick: onRightClick
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                if !isEnabled {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touchpad")
            .accessibilityIdentifier("touchpad.surface")
            .accessibilityHint(
                "Drag to move the Mac pointer, tap to click, use two fingers to scroll, "
                    + "or tap with two fingers to right-click"
            )
            .accessibilityAction(named: Text("Right-click")) {
                guard isEnabled else { return }
                onRightClick()
            }
            .accessibilityAction(.default) {
                guard isEnabled else { return }
                onTap()
            }
            .disabled(!isEnabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TrackpadSurface: UIViewRepresentable {
    let enabled: Bool
    let onMove: (Double, Double) -> Void
    let onScroll: (Double, Double) -> Void
    let onTap: () -> Void
    let onRightClick: () -> Void

    func makeUIView(context: Context) -> TrackpadView {
        let view = TrackpadView()
        view.onMove = onMove
        view.onScroll = onScroll
        view.onTap = onTap
        view.onRightClick = onRightClick
        view.isUserInteractionEnabled = enabled
        return view
    }

    func updateUIView(_ uiView: TrackpadView, context: Context) {
        uiView.onMove = onMove
        uiView.onScroll = onScroll
        uiView.onTap = onTap
        uiView.onRightClick = onRightClick
        uiView.isUserInteractionEnabled = enabled
    }
}

private final class TrackpadView: UIView, UIGestureRecognizerDelegate {
    var onMove: ((Double, Double) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    var onTap: (() -> Void)?
    var onRightClick: (() -> Void)?

    private lazy var pointerPan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self, action: #selector(handlePointerPan(_:)))
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var scrollPan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(
            target: self, action: #selector(handleScrollPan(_:)))
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        recognizer.numberOfTouchesRequired = 1
        recognizer.require(toFail: pointerPan)
        recognizer.require(toFail: rightTap)
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var rightTap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self, action: #selector(handleRightTap))
        recognizer.numberOfTouchesRequired = 2
        recognizer.require(toFail: scrollPan)
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(pointerPan)
        addGestureRecognizer(scrollPan)
        addGestureRecognizer(tap)
        addGestureRecognizer(rightTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePointerPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        onMove?(
            Double(translation.x.clamped(to: -500...500)),
            Double(translation.y.clamped(to: -500...500)))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleScrollPan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        onScroll?(
            Double(translation.x.clamped(to: -100...100)),
            Double(translation.y.clamped(to: -100...100)))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handleRightTap() {
        onRightClick?()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
