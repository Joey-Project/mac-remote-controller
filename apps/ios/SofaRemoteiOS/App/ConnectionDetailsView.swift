import SwiftUI

struct ConnectionDetailsView: View {
    @Bindable var model: RemoteModel
    let onSwitchTransport: () -> Void
    let onDisconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDetent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected Mac") {
                    LabeledContent("Mac", value: model.remoteState?.deviceName ?? "Mac")
                        .accessibilityIdentifier("connection.name")
                    LabeledContent(
                        "Status", value: model.isConnected ? "Connected" : "Disconnected"
                    )
                    .accessibilityIdentifier("connection.status")
                    LabeledContent("Connection", value: model.selectedTransport.rawValue)
                        .accessibilityIdentifier("connection.transport")
                }
                Section {
                    Button(action: onSwitchTransport) {
                        Label(
                            "Switch to \(model.selectedTransport == .wifi ? "Bluetooth LE" : "Wi-Fi")",
                            systemImage: model.selectedTransport == .wifi
                                ? "antenna.radiowaves.left.and.right" : "wifi")
                    }
                    .disabled(!model.isConnected)
                    .accessibilityIdentifier("remote.switchTransport")
                } footer: {
                    Text(
                        "Switching disconnects this session. Select your paired Mac again to reconnect."
                    )
                }
                Section {
                    NavigationLink {
                        ConnectionBenchmarkView(model: model)
                    } label: {
                        Label("Connection benchmark", systemImage: "speedometer")
                    }
                    .accessibilityIdentifier("remote.benchmark")
                }
                Section {
                    Button(role: .destructive, action: onDisconnect) {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("remote.disconnect")
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("connection.done")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
    }
}
