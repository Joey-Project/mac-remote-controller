import AppKit
import AppleCore
import SwiftUI

@MainActor
final class NumericPairingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var requestID: UUID?
    private var onCancel: (() -> Void)?

    func show(_ request: NumericPairingRequest?, onCancel: @escaping () -> Void) {
        guard let request else {
            requestID = nil
            self.onCancel = nil
            window?.orderOut(nil)
            return
        }
        let isNew = requestID != request.id
        requestID = request.id
        self.onCancel = onCancel
        let window: NSWindow
        if let existing = self.window {
            window = existing
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pair iPhone or iPad"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window.contentView = NSHostingView(
            rootView: NumericPairingRequestView(
                request: request, onCancel: onCancel))
        if isNew {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return true }
}

private struct NumericPairingRequestView: View {
    let request: NumericPairingRequest
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label(
                "Pair with \(request.deviceName)", systemImage: "iphone.radiowaves.left.and.right"
            )
            .font(.headline)
            Text("Enter this code in Sofa Remote on your iPhone or iPad.")
                .multilineTextAlignment(.center)
            Text(request.code)
                .font(.system(size: 48, weight: .semibold, design: .monospaced))
                .accessibilityLabel("Pairing code")
                .accessibilityValue(request.code)
                .accessibilityIdentifier("pairing.mac.code")
                .privacySensitive()
            Text(
                "\(request.remainingAttempts) attempts remaining · Expires \(request.expiresAt, style: .relative)"
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Cancel pairing", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 420)
    }
}
