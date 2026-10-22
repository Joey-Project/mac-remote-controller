import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct SofaRemoteMacApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        MenuBarExtra("Sofa Remote", systemImage: "appletvremote.gen4") {
            CompanionView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CompanionView: View {
    @Bindable var model: CompanionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sofa Remote").font(.title2.bold())
                Text(model.summary).foregroundStyle(.secondary)
                Label(
                    "\(model.connectedCount) connected",
                    systemImage: "iphone.radiowaves.left.and.right")
                if !model.remoteState.accessibilityGranted {
                    Text("Allow Accessibility to control the pointer and keyboard.")
                    Button("Allow Accessibility…") { model.desktop.requestAccessibility() }
                } else {
                    Label("Pointer and keyboard ready", systemImage: "checkmark.circle")
                }
                if let reason = model.remoteState.systemVolumeReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                if let invitation = model.invitation {
                    Text("Scan with Sofa Remote on iPhone or iPad.")
                    if let image = qrImage(invitation) {
                        Image(nsImage: image).interpolation(.none).resizable()
                            .frame(width: 240, height: 240).padding(12).background(.white)
                            .accessibilityLabel("Pairing invitation QR code")
                    }
                    if let expires = model.invitationExpiresAt {
                        Text("Expires \(expires, style: .relative)").font(.caption)
                    }
                    Button("Close pairing") { model.closePairing() }
                    Button("Copy invitation") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invitation, forType: .string)
                        NSPasteboard.general.setData(
                            Data(),
                            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                    }
                } else {
                    Button("Pair iPhone or iPad") { model.openPairing() }
                    Text(
                        "Both devices must be on the same local network. Pairing stays open for two minutes."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !model.pairedDevices.isEmpty {
                    Divider()
                    Text("Paired devices").font(.headline)
                    ForEach(model.pairedDevices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button("Remove", role: .destructive) { model.revoke(device) }
                        }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                Divider()
                Button("Quit Sofa Remote") { NSApplication.shared.terminate(nil) }
            }
            .padding(20)
        }
        .frame(width: 340).frame(maxHeight: 650)
    }

    private func qrImage(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
