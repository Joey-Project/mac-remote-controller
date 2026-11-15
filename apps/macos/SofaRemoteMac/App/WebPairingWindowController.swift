import AppKit
import SwiftUI
import WebRemoteSupport

@MainActor
final class WebPairingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var requestID: UUID?
    private var onCancel: (() -> Void)?

    func show(_ prompt: WebPairingPrompt?, onCancel: @escaping () -> Void) {
        guard let prompt else {
            requestID = nil; self.onCancel = nil; window?.orderOut(nil)
            return
        }
        let isNew = requestID != prompt.id
        requestID = prompt.id
        self.onCancel = onCancel
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "Pair Web browser"; created.isReleasedWhenClosed = false
            created.delegate = self; created.center(); window = created
        }
        window?.contentView = NSHostingView(
            rootView: WebPairingPromptView(prompt: prompt, onCancel: onCancel))
        if isNew { window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return true }
}

private struct WebPairingPromptView: View {
    let prompt: WebPairingPrompt
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label("Pair with \(prompt.deviceName)", systemImage: "globe").font(.headline)
            Text("Enter this code in your browser's Sofa Remote page.").multilineTextAlignment(
                .center)
            Text(prompt.code).font(.system(size: 48, weight: .semibold, design: .monospaced))
                .privacySensitive().accessibilityIdentifier("pairing.web.code")
            Text(
                "\(prompt.remainingAttempts) attempts remaining · Expires \(prompt.expiresAt, style: .relative)"
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Cancel pairing", role: .cancel, action: onCancel).keyboardShortcut(
                .cancelAction)
        }
        .padding(28).frame(width: 420)
    }
}
