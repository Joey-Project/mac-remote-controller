import SwiftUI

struct RemoteActionsMenu: View {
    @Bindable var model: RemoteModel
    @Binding var selectedMode: RemoteMode
    @Binding var isVolumePinned: Bool
    let gesturesSupported: Bool
    @Binding var threeFingerDragEnabled: Bool
    @Binding var fourFingerShortcutsEnabled: Bool
    @Binding var forceClickEnabled: Bool
    @Binding var hapticsEnabled: Bool
    let onTouchpad: () -> Void
    let onKeyboard: () -> Void
    let onSwitchTransport: () -> Void
    let onBenchmark: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Menu {
            Button(action: onTouchpad) {
                Label(
                    "Touchpad",
                    systemImage: selectedMode == .touchpad ? "checkmark" : "cursorarrow")
            }
            .accessibilityIdentifier("mode.touchpad")
            Button(action: onKeyboard) {
                Label(
                    "Keyboard",
                    systemImage: selectedMode == .keyboard ? "checkmark" : "keyboard")
            }
            .accessibilityIdentifier("mode.keyboard")
            Toggle(isOn: $isVolumePinned) {
                Label("Pin volume over touchpad", systemImage: "speaker.wave.2")
            }
            .accessibilityIdentifier("volume.pin")
            Divider()
            Toggle(isOn: $threeFingerDragEnabled) {
                Label("Three-finger drag", systemImage: "hand.draw")
            }
            .disabled(!gesturesSupported)
            .accessibilityIdentifier("gesture.drag")
            Toggle(isOn: $fourFingerShortcutsEnabled) {
                Label("Four-finger Mac shortcuts", systemImage: "rectangle.3.group")
            }
            .disabled(!gesturesSupported)
            .accessibilityIdentifier("gesture.shortcuts")
            Toggle(isOn: $forceClickEnabled) {
                Label("Pressure click when supported", systemImage: "hand.point.up.left")
            }
            .disabled(!gesturesSupported)
            .accessibilityIdentifier("gesture.force")
            Toggle(isOn: $hapticsEnabled) {
                Label("Haptic feedback", systemImage: "waveform")
            }
            .disabled(!gesturesSupported)
            .accessibilityIdentifier("gesture.haptics")
            Divider()
            Button(action: onSwitchTransport) {
                Label(
                    "Switch to \(model.selectedTransport == .wifi ? "Bluetooth LE" : "Wi-Fi")",
                    systemImage: model.selectedTransport == .wifi
                        ? "antenna.radiowaves.left.and.right" : "wifi")
            }
            .accessibilityIdentifier("remote.switchTransport")
            Button(action: onBenchmark) {
                Label("Connection benchmark", systemImage: "speedometer")
            }
            .accessibilityIdentifier("remote.benchmark")
            Button(role: .destructive, action: onDisconnect) {
                Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("remote.disconnect")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Remote controls")
        .accessibilityIdentifier("remote.menu")
    }
}
