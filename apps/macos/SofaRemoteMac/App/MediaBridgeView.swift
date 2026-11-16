import AppKit
import MacSupport
import SwiftUI

struct MediaBridgeView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Enable local media adapters",
                isOn: Binding(
                    get: { model.mediaAdapters.isEnabled },
                    set: { model.setMediaBridgeEnabled($0) })
            )
            .accessibilityIdentifier(CompanionControl.mediaEnabled.rawValue)
            Text(
                model.mediaAdapters.message
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Set Up IINA") {
                    model.mediaAdapters.setUpIINA()
                }
                .accessibilityIdentifier(CompanionControl.mediaSetupIINA.rawValue)
                Button("Set Up Chrome") {
                    model.mediaAdapters.setUpChrome()
                }
                .accessibilityIdentifier(CompanionControl.mediaSetupChrome.rawValue)
            }
            if let setupMessage = model.mediaAdapters.setupMessage {
                Text(setupMessage).font(.caption).textSelection(.enabled)
            }
            if model.mediaAdapters.isEnabled, model.mediaAdapters.token != nil,
                let port = model.mediaAdapters.port
            {
                DisclosureGroup(
                    "Manual setup",
                    isExpanded: Binding(
                        get: { model.mediaAdapters.manualSetupExpanded },
                        set: { model.mediaAdapters.manualSetupExpanded = $0 })
                ) {
                    Button("Copy token for IINA setup") {
                        model.mediaAdapters.copyToken()
                    }
                    .accessibilityIdentifier(CompanionControl.mediaCopyToken.rawValue)
                    .help("Paste into the Sofa Remote plugin preferences in IINA.")
                    Text(
                        "In IINA Preferences → Plugins → Sofa Remote, paste the copied token. "
                            + "The bridge port is \(port)."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(CompanionControl.mediaManualExpanded.rawValue)
            }
        }
    }
}
