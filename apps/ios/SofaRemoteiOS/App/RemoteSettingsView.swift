import CoreHaptics
import SwiftUI
import UIKit

struct RemoteSettingsView: View {
    @Binding var threeFingerDragEnabled: Bool
    @Binding var fourFingerShortcutsEnabled: Bool
    @Binding var forceClickEnabled: Bool
    @Binding var hapticsEnabled: Bool
    let companionSupportsGestures: Bool?
    @State private var forceTouchAvailable = false
    private let hapticsAvailable = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var companionUnavailable: Bool { companionSupportsGestures == false }

    var body: some View {
        Form {
            Section {
                Toggle("Three-finger drag", isOn: $threeFingerDragEnabled)
                    .disabled(companionUnavailable)
                    .accessibilityIdentifier("gesture.drag")
                Toggle("Four-finger Mac shortcuts", isOn: $fourFingerShortcutsEnabled)
                    .disabled(companionUnavailable)
                    .accessibilityIdentifier("gesture.shortcuts")
                Toggle("Pressure click when supported", isOn: $forceClickEnabled)
                    .disabled(companionUnavailable || !forceTouchAvailable)
                    .accessibilityIdentifier("gesture.force")
            } header: {
                Text("Touchpad gestures")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if companionUnavailable {
                        Text(
                            "This Mac does not support these gestures. Update its companion app to use them."
                        )
                    }
                    if !forceTouchAvailable {
                        Text(
                            "This device does not support pressure click. Standard taps remain available."
                        )
                        .accessibilityIdentifier("settings.forceUnavailable")
                    }
                }
            }
            Section {
                Toggle("Haptic feedback", isOn: $hapticsEnabled)
                    .disabled(companionUnavailable || !hapticsAvailable)
                    .accessibilityIdentifier("gesture.haptics")
            } header: {
                Text("Feedback")
            } footer: {
                if !hapticsAvailable {
                    Text("This device does not support haptic feedback.")
                        .accessibilityIdentifier("settings.hapticsUnavailable")
                }
            }
            Section {
                Text(
                    "Changes apply immediately and are saved on this device, including when no Mac is connected."
                )
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .background {
            ForceTouchAvailability { available in
                if forceTouchAvailable != available { forceTouchAvailable = available }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ForceTouchAvailability: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> ForceTouchProbeView {
        let view = ForceTouchProbeView(frame: .zero)
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ForceTouchProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportAvailability()
    }
}

private final class ForceTouchProbeView: UIView {
    var onChange: ((Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportAvailability()
    }

    func reportAvailability() {
        let available = traitCollection.forceTouchCapability == .available
        // Deliver after the UIKit update, rather than changing SwiftUI state inside it.
        DispatchQueue.main.async { [weak self] in self?.onChange?(available) }
    }
}
