import SwiftUI
import UIKit

struct ConnectionStatusCard: View {
    @Bindable var model: RemoteModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isConnected ? "checkmark.circle.fill" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(model.isConnected ? .green : .secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    model.isConnected
                        ? (model.remoteState?.deviceName ?? "Mac connected")
                        : "Connect to your Mac"
                )
                .font(.headline)
                Text(model.connectionSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !model.isConnected {
                Button {
                    model.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Refresh nearby Macs")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }
}

struct PairingPanel: View {
    @Bindable var model: RemoteModel
    @State private var invitation = ""
    @FocusState private var invitationFocused: Bool
    let onScan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Nearby Macs")
                    .font(.title3.weight(.semibold))
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Searching for Macs")
            }

            if model.discoveredMacs.isEmpty {
                ContentUnavailableView(
                    "No Macs found yet",
                    systemImage: "wifi.slash",
                    description: Text(
                        "Keep Sofa Remote open on your Mac and make sure both devices use the same network."
                    )
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.discoveredMacs) { mac in
                        Button {
                            model.connectSaved(to: mac)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mac.name).font(.body.weight(.medium))
                                    Text(mac.isPaired ? "Paired" : "Unpaired · scan QR code")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(
                                    systemName: mac.isPaired ? "arrow.right" : "qrcode.viewfinder"
                                )
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 13)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(!mac.isPaired)
                        .accessibilityHint(
                            mac.isPaired
                                ? "Reconnect to this Mac"
                                : "Scan the pairing QR code shown on this Mac")

                        if mac.id != model.discoveredMacs.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Button(action: onScan) {
                Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 8) {
                Text("Or paste an invitation")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 10) {
                    SecureField("Invitation code", text: $invitation)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($invitationFocused)
                        .submitLabel(.go)
                        .onSubmit(pairWithInvitation)
                        .padding(12)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                    Button("Pair", action: pairWithInvitation)
                        .buttonStyle(.bordered)
                        .disabled(
                            invitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }

    private func pairWithInvitation() {
        let trimmed = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.pair(invitation: trimmed)
        invitation = ""
        invitationFocused = false
    }
}
