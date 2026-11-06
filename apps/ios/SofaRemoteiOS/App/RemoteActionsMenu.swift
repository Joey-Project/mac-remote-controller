import AppleCore
import SwiftUI

struct RemoteActionsMenu: View {
    @Bindable var model: RemoteModel
    let onSettings: () -> Void

    var body: some View {
        Menu {
            sessionControls
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("remote.settings")
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
