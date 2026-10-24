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
            HStack {
                Button("Set Up IINA") {
                    guard let package = model.mediaAdapters.configureIINA() else { return }
                    NSWorkspace.shared.open(package)
                }
                Button("Set Up Chrome") {
                    guard let folder = model.mediaAdapters.configureChrome() else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                    if let chrome = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.google.Chrome"),
                        let page = URL(string: "chrome://extensions")
                    {
                        NSWorkspace.shared.open(
                            [page], withApplicationAt: chrome,
                            configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
            if let setupMessage = model.mediaAdapters.setupMessage {
                Text(setupMessage).font(.caption).textSelection(.enabled)
            }
            if model.mediaAdapters.isEnabled, let token = model.mediaAdapters.token,
                let port = model.mediaAdapters.port
            {
                DisclosureGroup("Manual setup") {
                    Button("Copy token for IINA setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                        NSPasteboard.general.setData(
                            Data(),
                            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    }
                    .help("Paste into the Sofa Remote plugin preferences in IINA.")
                    Text(
                        "In IINA Preferences → Plugins → Sofa Remote, paste the copied token. "
                            + "The bridge port is \(port)."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
