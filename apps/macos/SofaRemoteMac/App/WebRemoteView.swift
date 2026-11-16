import AppKit
import MacSupport
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
                .accessibilityIdentifier(CompanionControl.webEnabled.rawValue)
                .disabled(controller.busy)
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
            if !controller.dnsStatus.isEmpty {
                Text(controller.dnsStatus).font(.caption).foregroundStyle(.secondary)
            }
            if controller.address != nil {
                HStack {
                    Button("Open in browser") { controller.openInBrowser() }
                        .accessibilityIdentifier(CompanionControl.webOpen.rawValue)
                    Button("Copy URL") {
                        controller.copyURL()
                    }
                    .accessibilityIdentifier(CompanionControl.webCopyURL.rawValue)
                }
            }
            HStack {
                Button("Web setup folder…") { controller.openFolder() }
                    .accessibilityIdentifier(CompanionControl.webOpenFolder.rawValue)
                Button("Reload setup") { controller.reload() }.disabled(controller.busy)
                    .accessibilityIdentifier(CompanionControl.webReload.rawValue)
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
