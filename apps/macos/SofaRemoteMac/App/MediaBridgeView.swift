import AppKit
import SwiftUI

struct MediaBridgeView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Enable local media adapters",
                isOn: Binding(
                    get: { model.mediaAdapters.isEnabled },
                    set: { model.setMediaBridgeEnabled($0) }))
            Text(
                model.mediaAdapters.message
            )
            .font(.caption).foregroundStyle(.secondary)
            if model.mediaAdapters.isEnabled, let token = model.mediaAdapters.token {
                Button("Copy token for IINA setup") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(token, forType: .string)
                    NSPasteboard.general.setData(
                        Data(),
                        forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                }
                .help("Paste into the Sofa Remote plugin preferences in IINA.")
                Text(
                    "In IINA Preferences → Plugins → Sofa Remote, paste the copied token. The bridge port is 47623."
                )
                .font(.caption2).foregroundStyle(.secondary)
                Text("Load the built Chrome extension and install its native messaging helper.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
