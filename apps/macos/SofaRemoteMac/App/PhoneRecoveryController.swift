import AppKit
import MacSupport
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PhoneRecoveryController {
    private(set) var configured = false
    private(set) var isBusy = false
    private(set) var message =
        "Choose an existing free-account renewal setup to enable manual recovery."
    private var configuration: URL?

    init() {
        if let path = UserDefaults.standard.string(forKey: "phoneRecoveryConfiguration") {
            configuration = URL(fileURLWithPath: path)
            configured = (try? PhoneRecoveryConfiguration.load(URL(fileURLWithPath: path))) != nil
            if configured { message = "Manual phone recovery is configured." }
        }
    }

    func chooseSetup() {
        let panel = NSOpenPanel()
        panel.title = "Choose the private renewal configuration"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isBusy = true
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SofaRemote/Recovery")
        Task {
            do {
                let saved = try await Task.detached {
                    try PhoneRecoveryTool.configure(from: source, directory: directory)
                }.value
                configuration = saved
                UserDefaults.standard.set(saved.path, forKey: "phoneRecoveryConfiguration")
                configured = true
                message = "Recovery setup saved. Its accepted app copy is retained on this Mac."
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }

    func reinstall() {
        guard let configuration, !isBusy,
            let runner = Bundle.main.resourceURL?.appendingPathComponent("PhoneRecovery/renew.py")
        else { return }
        isBusy = true
        message = "Renewing the signature and reinstalling the accepted iPhone/iPad app…"
        Task {
            do {
                let receipt = try await Task.detached {
                    try PhoneRecoveryTool.run(configuration: configuration, runner: runner)
                }.value
                let expiry = receipt.expiration ?? "the new profile expiry"
                message = "App re-signed and installation confirmed. Valid until \(expiry)."
            } catch { message = error.localizedDescription }
            isBusy = false
        }
    }
}

struct PhoneRecoveryView: View {
    @Bindable var controller: PhoneRecoveryController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone / iPad recovery").font(.headline)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Renewal Setup…") { controller.chooseSetup() }
                if controller.configured {
                    Button("Re-sign & Reinstall…") { controller.reinstall() }
                }
            }
            Text(
                "Uses your saved local renewal session. "
                    + "Keep the phone paired over Wi-Fi or USB; unlock it if requested."
            )
            .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(controller.isBusy)
    }
}
