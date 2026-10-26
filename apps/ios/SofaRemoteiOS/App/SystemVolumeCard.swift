import AppleCore
import SwiftUI

struct SystemVolumeCard: View {
    @Bindable var model: RemoteModel
    @Binding var volumeScope: VolumeScope
    let target: MediaTarget?
    let onSetPlayerVolume: (MediaTarget, Double, Double, String) -> Bool

    @State private var volumeValue = 0.5
    @State private var isEditing = false

    private var systemVolume: Double? { model.remoteState?.systemVolume }
    private var playerMaximum: Double? {
        guard let maximumGainRatio = target?.capabilities.playerVolumeMaximum else { return nil }
        return PlayerVolumePolicy.uiMaximumPercent(fromGainRatio: maximumGainRatio)
    }
    private var playerVolumePercent: Double? {
        guard let target, let maximumGainRatio = target.capabilities.playerVolumeMaximum,
            let playerVolume = target.playerVolume
        else { return nil }
        return PlayerVolumePolicy.uiPercent(
            fromGainRatio: playerVolume, maximumGainRatio: maximumGainRatio)
    }
    private var isPlayerScope: Bool { volumeScope == .player }
    private var canUsePlayerVolume: Bool {
        playerMaximum != nil && playerVolumePercent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            volumeControl
            if !isPlayerScope, systemVolume == nil { unavailableSystemVolume }
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

    private var header: some View {
        HStack(spacing: 8) {
            Label(
                isPlayerScope ? "Player volume" : "Mac volume", systemImage: "speaker.wave.2"
            )
            .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                volumeScope = isPlayerScope ? .system : .player
            } label: {
                HStack(spacing: 5) {
                    Text(isPlayerScope ? "Player" : "System")
                    Image(systemName: "arrow.left.arrow.right")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: Capsule())
            }
            .disabled(!canUsePlayerVolume && !isPlayerScope)
            .accessibilityLabel(
                isPlayerScope ? "Switch to Mac system volume" : "Switch to player volume"
            )
            .accessibilityIdentifier("volume.scope")
            playerVolumeSummary
            if !isPlayerScope { systemVolumeSummary }
        }
    }

    @ViewBuilder
    private var playerVolumeSummary: some View {
        if isPlayerScope, let volume = playerVolumePercent {
            Text((volume / 100).formatted(.percent.precision(.fractionLength(0))))
                .font(.subheadline.weight(.medium)).monospacedDigit()
        } else if isPlayerScope {
            Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var systemVolumeSummary: some View {
        if let systemVolume {
            Text(systemVolume.formatted(.percent.precision(.fractionLength(0))))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .accessibilityLabel(systemVolume.formatted(.percent.precision(.fractionLength(0))))
        } else {
            Text("Unavailable")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Volume unavailable")
        }
    }

    @ViewBuilder
    private var volumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            if isPlayerScope {
                playerVolumeControl
            } else {
                systemVolumeControl
            }
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playerVolumeControl: some View {
        if let target, let maximum = playerMaximum {
            PlayerVolumeSliderControl(
                target: target, maximum: maximum, isConnected: model.isConnected,
                displayState: model.playerVolumeDisplayStates[target.id]
            ) { value, displayPercent, requestID in
                onSetPlayerVolume(target, value, displayPercent, requestID)
            }
            .id(target.id)
            .accessibilityLabel("Selected player volume")
            .accessibilityIdentifier("volume.player.slider")
        } else {
            Text("Player volume is unavailable for this source.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var systemVolumeControl: some View {
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
        .accessibilityLabel("Mac system volume")
        .accessibilityIdentifier("volume.slider")
    }

    @ViewBuilder
    private var unavailableSystemVolume: some View {
        Text(
            model.remoteState?.systemVolumeReason
                ?? "System volume control is unavailable on this Mac."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func syncFromRemote() {
        guard !isEditing, let systemVolume else { return }
        volumeValue = systemVolume
    }
}

private struct PlayerVolumeSliderControl: View {
    let target: MediaTarget
    let maximum: Double
    let isConnected: Bool
    let displayState: PlayerVolumeDisplayState?
    let onSetVolume: (Double, Double, String) -> Bool

    private var currentVolumePercent: Double? {
        guard let maximumGainRatio = target.capabilities.playerVolumeMaximum,
            let playerVolume = target.playerVolume
        else { return nil }
        return PlayerVolumePolicy.uiPercent(
            fromGainRatio: playerVolume, maximumGainRatio: maximumGainRatio)
    }

    @State private var sliderValue: Double
    @State private var isEditing = false

    init(
        target: MediaTarget, maximum: Double, isConnected: Bool,
        displayState: PlayerVolumeDisplayState?,
        onSetVolume: @escaping (Double, Double, String) -> Bool
    ) {
        self.target = target
        self.maximum = maximum
        self.isConnected = isConnected
        self.displayState = displayState
        self.onSetVolume = onSetVolume
        let initialValue = displayState?.displayedValue ?? Self.uiPercent(for: target)
        _sliderValue = State(initialValue: initialValue ?? 0)
    }

    var body: some View {
        Slider(
            value: Binding(get: { sliderValue }, set: { setVolume($0) }), in: 0...maximum,
            onEditingChanged: updateEditingState
        )
        .disabled(!isConnected || currentVolumePercent == nil)
        .accessibilityAdjustableAction(adjustForAccessibility)
        .onChange(of: currentVolumePercent) { _, newValue in syncRemoteVolume(newValue) }
        .onChange(of: maximum) { _, _ in syncRemoteVolume(currentVolumePercent) }
        .onChange(of: isConnected) { _, _ in syncRemoteVolume(currentVolumePercent) }
        .onChange(of: displayState) { _, newValue in
            guard !isEditing else { return }
            sliderValue = newValue?.displayedValue ?? currentVolumePercent ?? 0
        }
    }

    private func updateEditingState(_ editing: Bool) {
        isEditing = editing
        if editing {
            sliderValue = displayValue ?? sliderValue
        } else {
            sliderValue = displayValue ?? sliderValue
        }
    }

    private func adjustForAccessibility(_ direction: AccessibilityAdjustmentDirection) {
        guard
            let adjusted = PlayerVolumePolicy.accessibilityAdjustedValue(
                current: sliderValue, increasing: direction == .increment, maximum: maximum)
        else { return }
        setVolume(adjusted)
    }

    private func setVolume(_ proposed: Double) {
        guard let snapped = PlayerVolumePolicy.snappedValue(proposed: proposed, maximum: maximum),
            snapped != sliderValue,
            PlayerVolumePolicy.shouldSend(
                value: snapped, current: displayValue, previouslySent: nil)
        else { return }
        guard let maximumGainRatio = target.capabilities.playerVolumeMaximum,
            let gainRatio = PlayerVolumePolicy.gainRatio(
                fromUIPercent: snapped, maximumGainRatio: maximumGainRatio)
        else { return }
        let requestID = UUID().uuidString
        if onSetVolume(gainRatio, snapped, requestID) {
            sliderValue = snapped
        } else {
            sliderValue = displayValue ?? currentVolumePercent ?? snapped
        }
    }

    private func syncRemoteVolume(_ newValue: Double?) {
        guard !isEditing else { return }
        sliderValue = displayValue ?? newValue ?? 0
    }

    private var displayValue: Double? {
        displayState?.displayedValue ?? currentVolumePercent
    }

    private static func uiPercent(for target: MediaTarget) -> Double? {
        guard let maximumGainRatio = target.capabilities.playerVolumeMaximum,
            let playerVolume = target.playerVolume
        else { return nil }
        return PlayerVolumePolicy.uiPercent(
            fromGainRatio: playerVolume, maximumGainRatio: maximumGainRatio)
    }
}
