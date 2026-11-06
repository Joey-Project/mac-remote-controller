import SwiftUI

struct RemoteToolbar: ToolbarContent {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: RemoteModel
    let selectedMode: RemoteMode
    @Binding var isVolumePinned: Bool
    let onSwitchMode: () -> Void
    let onConnectionDetails: () -> Void
    let onSettings: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: onSwitchMode) {
                Image(systemName: selectedMode == .touchpad ? "keyboard" : "cursorarrow")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(
                selectedMode == .touchpad ? "Switch to Keyboard" : "Switch to Touchpad"
            )
            .accessibilityValue(selectedMode.rawValue)
            .accessibilityIdentifier(selectedMode == .touchpad ? "mode.keyboard" : "mode.touchpad")
        }
        ToolbarItem(placement: .principal) {
            Button(action: onConnectionDetails) {
                HStack(spacing: 4) {
                    Text(model.remoteState?.deviceName ?? "Mac")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: horizontalSizeClass == .compact ? 140 : 280)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Connection details for \(model.remoteState?.deviceName ?? "Mac")")
            .accessibilityValue(model.selectedTransport.rawValue)
            .accessibilityIdentifier("remote.connectionDetails")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectedMode == .touchpad {
                Button {
                    isVolumePinned.toggle()
                } label: {
                    Image(systemName: isVolumePinned ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(
                    isVolumePinned
                        ? "Hide volume and playback controls" : "Show volume and playback controls"
                )
                .accessibilityValue(isVolumePinned ? "Visible" : "Hidden")
                .accessibilityIdentifier("volume.pin")
            }
            RemoteActionsMenu(model: model, onSettings: onSettings)
        }
    }
}
