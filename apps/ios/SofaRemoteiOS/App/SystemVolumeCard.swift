import AppleCore
import SwiftUI

struct SystemVolumeCard: View {
    @Bindable var model: RemoteModel
    @State private var volumeValue = 0.5
    @State private var isEditing = false

    private var systemVolume: Double? { model.remoteState?.systemVolume }

    var body: some View {
        let volumeText =
            systemVolume?.formatted(.percent.precision(.fractionLength(0))) ?? "Unavailable"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Mac volume", systemImage: "speaker.wave.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(volumeText)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(systemVolume == nil ? .secondary : .primary)
                    .accessibilityLabel(systemVolume == nil ? "Volume unavailable" : volumeText)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { isEditing ? volumeValue : systemVolume ?? volumeValue },
                        set: {
                            volumeValue = $0
                            model.send(RemoteCommand(name: .systemVolumeSet, value: $0))
                        }
                    ), in: 0...1,
                    onEditingChanged: { editing in
                        isEditing = editing
                        if !editing { syncFromRemote() }
                    }
                )
                .disabled(!model.isConnected || systemVolume == nil)
                .accessibilityLabel("Mac system volume").accessibilityIdentifier("volume.slider")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if systemVolume == nil {
                Text(
                    model.remoteState?.systemVolumeReason
                        ?? "System volume control is unavailable on this Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("volume.card")
        .onAppear(perform: syncFromRemote)
        .onChange(of: systemVolume) { _, _ in syncFromRemote() }
        .onDisappear {
            isEditing = false
            syncFromRemote()
        }
    }

    private func syncFromRemote() {
        guard !isEditing, let systemVolume else { return }
        volumeValue = systemVolume
    }
}
