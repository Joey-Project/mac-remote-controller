import AppleCore
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
            sessionControls
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

    @ViewBuilder
    private var sessionControls: some View {
        if let state = model.remoteState {
            let capabilities = state.capabilities ?? []
            if state.sessionLocked == true {
                if capabilities.contains(WireCapabilities.remoteUnlock) {
                    control(
                        "Unlock Mac", icon: "lock.open", command: .sessionUnlock,
                        identifier: "remote.unlock")
                }
            } else if capabilities.contains(WireCapabilities.remoteLock) {
                control("Lock Mac", icon: "lock", command: .sessionLock, identifier: "remote.lock")
            } else if capabilities.contains(WireCapabilities.remoteUnlock) {
                control(
                    "Mac unlocked", icon: "lock.open", command: .sessionUnlock,
                    identifier: "remote.unlock")
            }
            if capabilities.contains(WireCapabilities.displayPower) {
                if state.displayAsleep == true {
                    control(
                        "Wake Display", icon: "display", command: .displayWake,
                        identifier: "remote.displayWake")
                } else {
                    control(
                        "Turn Display Off", icon: "display", command: .displayOff,
                        identifier: "remote.displayOff")
                }
                if capabilities.contains(WireCapabilities.remoteLock) {
                    control(
                        "Lock & Turn Display Off", icon: "lock.display",
                        command: .sessionLockAndDisplayOff,
                        identifier: "remote.lockDisplayOff")
                }
            }
            if capabilities.contains(WireCapabilities.remoteUnlock)
                || capabilities.contains(WireCapabilities.remoteLock)
                || capabilities.contains(WireCapabilities.displayPower)
            {
                Divider()
            }
        }
    }

    private func control(
        _ title: String, icon: String, command: CommandName, identifier: String
    ) -> some View {
        Button {
            model.send(RemoteCommand(name: command))
        } label: {
            Label(title, systemImage: icon)
        }
        .disabled(
            model.remoteState.map { !SessionControlPolicy.allows(command, state: $0) } ?? true
        )
        .accessibilityIdentifier(identifier)
    }
}
