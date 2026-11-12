import AppleCore
import SwiftUI

struct RemoteControlPanels<Playback: View>: View {
    @Bindable var model: RemoteModel
    @Binding var volumeScope: VolumeScope
    let target: MediaTarget?
    let showsVolume: Bool
    let showsDesktop: Bool
    let playback: Playback
    let onDesktopAction: (SystemShortcut) -> Void

    var body: some View {
        VStack(spacing: 10) {
            if showsVolume {
                SystemVolumeCard(
                    model: model, volumeScope: $volumeScope, target: target,
                    onSetPlayerVolume: { target, value, displayPercent, requestID in
                        model.sendPlayerVolume(
                            targetID: target.id, gainRatio: value, displayPercent: displayPercent,
                            requestID: requestID)
                    })
                playback
            }
            if showsDesktop {
                DesktopControlsCard(
                    isEnabled: model.isConnected && model.remoteState?.accessibilityGranted == true
                        && model.remoteState?.supportsGestures == true,
                    companionSupportsActions: model.remoteState?.supportsGestures == true,
                    accessibilityGranted: model.remoteState?.accessibilityGranted == true,
                    onAction: onDesktopAction)
            }
        }
    }
}

struct DesktopControlsCard: View {
    let isEnabled: Bool
    let companionSupportsActions: Bool
    let accessibilityGranted: Bool
    let onAction: (SystemShortcut) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Desktop controls", systemImage: "macwindow")
                .font(.headline)
            HStack(alignment: .top, spacing: 8) {
                control("Previous desktop", icon: "arrow.left", action: .previousSpace)
                control("Mission Control", icon: "square.grid.2x2", action: .missionControl)
                control("App windows", icon: "macwindow.on.rectangle", action: .appExpose)
                control("Next desktop", icon: "arrow.right", action: .nextSpace)
            }
            if !companionSupportsActions {
                Text("Update the Mac companion to use desktop controls.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !accessibilityGranted {
                Text("Allow Accessibility on your Mac to use desktop controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: 620, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("desktop.card")
    }

    private func control(_ title: String, icon: String, action: SystemShortcut) -> some View {
        Button {
            if isEnabled { onAction(action) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .accessibilityLabel(title)
        .accessibilityIdentifier("desktop.\(action.rawValue)")
    }
}
