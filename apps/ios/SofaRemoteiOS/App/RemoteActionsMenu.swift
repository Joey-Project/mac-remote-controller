import SwiftUI

struct RemoteActionsMenu: View {
    @Bindable var model: RemoteModel
    @Binding var selectedMode: RemoteMode
    @Binding var isVolumePinned: Bool
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
