import SwiftUI

struct RemoteToolbar: ToolbarContent {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var model: RemoteModel
    let selectedMode: RemoteMode
    @Binding var isVolumePinned: Bool
    @Binding var isDesktopPinned: Bool
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
            Menu {
                Toggle("Volume and playback", isOn: $isVolumePinned)
                    .accessibilityIdentifier("panels.volume")
                Toggle("Desktop controls", isOn: $isDesktopPinned)
                    .accessibilityIdentifier("panels.desktop")
                Divider()
                Button("Hide all controls") {
                    isVolumePinned = false
                    isDesktopPinned = false
                }
                .disabled(!isVolumePinned && !isDesktopPinned)
                .accessibilityIdentifier("panels.hideAll")
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Control panels")
            .menuActionDismissBehavior(.enabled)
            .accessibilityValue(panelSummary)
            .accessibilityIdentifier("remote.panels")
            RemoteActionsMenu(model: model, onSettings: onSettings)
        }
    }

    private var panelSummary: String {
        switch (isVolumePinned, isDesktopPinned) {
        case (false, false): "All hidden"
        case (true, false): "Volume and playback"
        case (false, true): "Desktop controls"
        case (true, true): "Volume and playback, Desktop controls"
        }
    }
}
