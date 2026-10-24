import AppleCore
import SwiftUI
import UIKit

extension RemoteView {
    var systemVolumeCard: some View {
        let systemVolume = model.remoteState?.systemVolume
        let playerMaximum = selectedMediaTarget?.capabilities.playerVolumeMaximum
        let showPlayerVolume = volumeScope == .player
        let volumeText =
            systemVolume?.formatted(.percent.precision(.fractionLength(0)))
            ?? "Unavailable"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    showPlayerVolume ? "Player volume" : "Mac volume", systemImage: "speaker.wave.2"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                if model.remoteState?.mediaTargets != nil {
                    Picker("Volume scope", selection: $volumeScope) {
                        Text("System").tag(VolumeScope.system)
                        Text("Player").tag(VolumeScope.player)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                    .accessibilityIdentifier("volume.scope")
                }
                if showPlayerVolume, let playerMaximum,
                    let playerVolume = selectedMediaTarget?.playerVolume
                {
                    Text(
                        playerVolume.formatted(.number.precision(.fractionLength(0))) + " / "
                            + playerMaximum.formatted(.number.precision(.fractionLength(0)))
                    )
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                } else if showPlayerVolume {
                    Text("Unavailable").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(volumeText)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(systemVolume == nil ? .secondary : .primary)
                        .accessibilityLabel(systemVolume == nil ? "Volume unavailable" : volumeText)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                if showPlayerVolume, let playerMaximum {
                    playerVolumeSlider(maximum: playerMaximum)
                } else if showPlayerVolume {
                    Text("Player volume is unavailable for this source.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Slider(
                        value: Binding(
                            get: { isVolumeEditing ? volumeValue : systemVolume ?? volumeValue },
                            set: {
                                volumeValue = $0
                                model.send(RemoteCommand(name: .systemVolumeSet, value: $0))
                            }
                        ), in: 0...1,
                        onEditingChanged: { editing in
                            isVolumeEditing = editing
                            if !editing {
                                syncSystemVolumeFromRemote()
                            }
                        }
                    )
                    .disabled(!model.isConnected || systemVolume == nil)
                    .accessibilityLabel("Mac system volume").accessibilityIdentifier(
                        "volume.slider")
                }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if !showPlayerVolume, systemVolume == nil {
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
        .frame(maxWidth: .infinity).accessibilityElement(children: .contain)
        .accessibilityIdentifier("volume.card")
        .onAppear(perform: syncSystemVolumeFromRemote)
        .onChange(of: model.remoteState?.systemVolume) { _, _ in
            syncSystemVolumeFromRemote()
        }
        .onDisappear {
            isVolumeEditing = false
            syncSystemVolumeFromRemote()
        }
    }

    var mediaTargetIDs: [String]? {
        model.remoteState?.mediaTargets?.map(\.id)
    }

    var selectedMediaTarget: MediaTarget? {
        guard let targets = model.remoteState?.mediaTargets,
            let selectedMediaTargetID
        else { return nil }
        return targets.first(where: { $0.id == selectedMediaTargetID })
    }

    var mediaControlsCard: some View {
        Group {
            if let targets = model.remoteState?.mediaTargets {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Player", systemImage: "play.rectangle")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !targets.isEmpty {
                            Picker(
                                "Media source",
                                selection: Binding(
                                    get: { selectedMediaTargetID ?? "" },
                                    set: { selectedMediaTargetID = $0 }
                                )
                            ) {
                                Text("Choose player").tag("")
                                ForEach(targets) { target in
                                    Text(target.name).tag(target.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("media.target")
                        }
                    }
                    if let target = selectedMediaTarget {
                        HStack(spacing: 12) {
                            Button {
                                sendMedia(.previous, target: target)
                            } label: {
                                Image(systemName: "backward.end.fill")
                            }
                            .disabled(!target.capabilities.previous)
                            .accessibilityLabel("Previous item")
                            Button {
                                sendMedia(.playPause, target: target)
                            } label: {
                                Image(systemName: "playpause.fill")
                            }
                            .disabled(!target.capabilities.playPause)
                            .accessibilityLabel("Play or pause")
                            Button {
                                sendMedia(.seek, target: target, value: -seekInterval)
                            } label: {
                                Image(systemName: "gobackward.\(Int(seekInterval))")
                            }
                            .disabled(!target.capabilities.seek)
                            .accessibilityLabel("Seek backward \(Int(seekInterval)) seconds")
                            Menu {
                                ForEach([5.0, 10.0, 30.0], id: \.self) { seconds in
                                    Button("\(Int(seconds)) seconds") { seekInterval = seconds }
                                }
                            } label: {
                                Text("±\(Int(seekInterval))s")
                                    .font(.caption.monospacedDigit())
                                    .frame(minWidth: 42, minHeight: 44)
                            }
                            .accessibilityLabel("Seek interval")
                            Button {
                                sendMedia(.seek, target: target, value: seekInterval)
                            } label: {
                                Image(systemName: "goforward.\(Int(seekInterval))")
                            }
                            .disabled(!target.capabilities.seek)
                            .accessibilityLabel("Seek forward \(Int(seekInterval)) seconds")
                            Button {
                                sendMedia(.next, target: target)
                            } label: {
                                Image(systemName: "forward.end.fill")
                            }
                            .disabled(!target.capabilities.next)
                            .accessibilityLabel("Next item")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("No supported media player is currently available.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: 620, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("media.controls")
            }
        }
    }

    @ViewBuilder
    func playerVolumeSlider(maximum: Double) -> some View {
        let current = selectedMediaTarget?.playerVolume ?? playerVolumeValue
        let step = maximum / 10
        Slider(
            value: Binding(
                get: { isPlayerVolumeEditing ? playerVolumeValue : current },
                set: { proposed in
                    let snapped =
                        proposed >= maximum * 0.96
                        ? maximum
                        : (proposed / step).rounded() * step
                    if snapped == maximum && !playerVolumeDetentActive {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    playerVolumeDetentActive = snapped == maximum
                    playerVolumeValue = snapped
                    guard let target = selectedMediaTarget else { return }
                    sendMedia(.setVolume, target: target, value: snapped)
                }
            ), in: 0...maximum, step: step,
            onEditingChanged: { editing in
                isPlayerVolumeEditing = editing
                if !editing { playerVolumeDetentActive = false }
            }
        )
        .disabled(!model.isConnected || selectedMediaTarget?.playerVolume == nil)
        .accessibilityLabel("Selected player volume")
        .accessibilityIdentifier("volume.player.slider")
    }

    func sendMedia(_ action: MediaAction, target: MediaTarget, value: Double? = nil) {
        model.send(
            RemoteCommand(
                name: .mediaControl,
                mediaRequest: MediaRequest(targetID: target.id, action: action, value: value)))
    }

    func syncSystemVolumeFromRemote() {
        guard !isVolumeEditing, let systemVolume = model.remoteState?.systemVolume else { return }
        volumeValue = systemVolume
    }
}
