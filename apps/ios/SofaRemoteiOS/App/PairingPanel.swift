import SwiftUI

struct PairingPanel: View {
    @Bindable var model: RemoteModel
    @State private var invitation = ""
    @FocusState private var invitationFocused: Bool
    let onScan: () -> Void

    private var candidates: [DiscoveredMac] {
        model.selectedTransport == .wifi ? model.discoveredMacs : model.pairedMacChoices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(
                "Connection transport",
                selection: Binding(
                    get: { model.selectedTransport },
                    set: { model.selectTransport($0) })
            ) {
                ForEach(RemoteTransportKind.allCases) { transport in
                    Text(transport.rawValue).tag(transport)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("connection.transport")

            HStack {
                Text(model.selectedTransport == .wifi ? "Nearby Macs" : "Paired Macs")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.selectedTransport == .wifi {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching for Macs")
                }
            }

            if candidates.isEmpty {
                ContentUnavailableView(
                    model.selectedTransport == .wifi ? "No Macs found yet" : "No paired Macs yet",
                    systemImage: model.selectedTransport == .wifi
                        ? "wifi.slash" : "iphone.radiowaves.left.and.right",
                    description: Text(
                        model.selectedTransport == .wifi
                            ? "Keep Sofa Remote open on your Mac and make sure both devices use the same network."
                            : "Pair with your Mac over Wi-Fi first. Bluetooth is available only for paired Macs."
                    )
                )
                .frame(minHeight: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { mac in
                        Button {
                            model.connectSaved(to: mac)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mac.name).font(.body.weight(.medium))
                                    Text(
                                        model.selectedTransport == .bluetooth
                                            ? "Paired · Bluetooth LE"
                                            : (mac.isPaired ? "Paired" : "Unpaired · scan QR code")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(
                                    systemName: model.selectedTransport == .bluetooth
                                        || mac.isPaired
                                        ? "arrow.right" : "qrcode.viewfinder"
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
                                ? "Reconnect to this Mac over \(model.selectedTransport.rawValue)"
                                : "Scan the pairing QR code shown on this Mac")

                        if mac.id != candidates.last?.id {
                            Divider()
                        }
                    }
                }
            }

            Button(action: onScan) {
                Label(
                    model.selectedTransport == .wifi
                        ? "Scan pairing QR code" : "Pair over Wi-Fi first",
                    systemImage: "qrcode.viewfinder"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedTransport == .bluetooth)

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
                        .disabled(model.selectedTransport == .bluetooth)
                        .onSubmit(pairWithInvitation)
                        .padding(12)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                    Button("Pair", action: pairWithInvitation)
                        .buttonStyle(.bordered)
                        .disabled(
                            model.selectedTransport == .bluetooth
                                || invitation.trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                        )
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
