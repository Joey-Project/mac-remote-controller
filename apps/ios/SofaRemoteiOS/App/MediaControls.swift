import AppleCore
import SwiftUI

extension RemoteView {
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
                        HStack(spacing: 8) {
                            Button {
                                sendMedia(.previous, target: target)
                            } label: {
                                Image(systemName: "backward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .disabled(!target.capabilities.previous)
                            .accessibilityLabel("Previous item")
                            Button {
                                sendMedia(.seek, target: target, value: -10)
                            } label: {
                                Image(systemName: "gobackward.10")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .disabled(!target.capabilities.seek)
                            .accessibilityLabel("Seek backward 10 seconds")
                            Button {
                                sendMedia(.playPause, target: target)
                            } label: {
                                Image(systemName: "playpause.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .disabled(!target.capabilities.playPause)
                            .accessibilityLabel("Play or pause")
                            Button {
                                sendMedia(.seek, target: target, value: 10)
                            } label: {
                                Image(systemName: "goforward.10")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .disabled(!target.capabilities.seek)
                            .accessibilityLabel("Seek forward 10 seconds")
                            Button {
                                sendMedia(.next, target: target)
                            } label: {
                                Image(systemName: "forward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44)
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
            }
        }
    }

    func sendMedia(_ action: MediaAction, target: MediaTarget, value: Double? = nil) {
        model.send(
            RemoteCommand(
                name: .mediaControl,
                mediaRequest: MediaRequest(targetID: target.id, action: action, value: value)))
    }

}
