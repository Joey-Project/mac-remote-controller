import AppKit
import SwiftUI

struct WebRemoteView: View {
    @Bindable var controller: WebRemoteController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Web remote").font(.headline)
            if controller.hasConfiguration {
                Toggle(
                    "Enable Web remote",
                    isOn: Binding(
                        get: { controller.enabled }, set: { controller.setEnabled($0) })
                )
                .disabled(controller.busy)
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if !controller.dnsStatus.isEmpty {
                Text(controller.dnsStatus).font(.caption).foregroundStyle(.secondary)
            }
            if let address = controller.address {
                HStack {
                    Button("Open in browser") { NSWorkspace.shared.open(address) }
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address.absoluteString, forType: .string)
                    }
                }
            }
            HStack {
                Button("Web setup folder…") { controller.openFolder() }
                Button("Reload setup") { controller.reload() }.disabled(controller.busy)
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
