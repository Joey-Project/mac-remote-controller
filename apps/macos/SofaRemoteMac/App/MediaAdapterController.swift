import AppleCore
import Foundation
import MacSupport
import Observation

@MainActor
@Observable
final class MediaAdapterController {
    private(set) var isEnabled = false
    private(set) var token: String?
    private(set) var message = "Local media bridge is off."
    private(set) var setupMessage: String?
    let router = MediaRouter()
    var onTargetsChanged: (([MediaTarget]?) -> Void)?

    private var bridge: LoopbackMediaBridge?

    func restoreEnabled() {
        if UserDefaults.standard.bool(forKey: "mediaBridgeEnabled") { setEnabled(true) }
    }

    var isRunning: Bool { bridge?.isRunning == true }
    var port: UInt16? { bridge?.configuration.port }
    var mediaTargets: [MediaTarget]? {
        guard isRunning else { return nil }
        return router.targets.values.sorted { $0.id < $1.id }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mediaBridgeEnabled")
        guard enabled != isEnabled else { return }
        if !enabled {
            bridge?.stop()
            bridge = nil
            isEnabled = false
            token = nil
            message = "Local media bridge is off."
            removeAllTargets()
            onTargetsChanged?(nil)
            return
        }

        do {
            let configuration = try MediaBridgeConfiguration.loadOrCreate()
            let bridge = LoopbackMediaBridge(configuration: configuration, router: router)
            bridge.onTargetsChanged = { [weak self] targets in self?.onTargetsChanged?(targets) }
            bridge.onFailure = { [weak self] message in
                guard let self else { return }
                self.message = message
                self.isEnabled = false
                self.token = nil
                self.bridge = nil
                self.removeAllTargets()
                self.onTargetsChanged?(nil)
            }
            try bridge.start()
            self.bridge = bridge
            isEnabled = true
            token = configuration.token
            message = "Listening on 127.0.0.1:\(configuration.port)."
            onTargetsChanged?(mediaTargets)
        } catch {
            isEnabled = false
            token = nil
            message = error.localizedDescription
        }
    }

    func expireStaleTargets() {
        bridge?.expireStaleTargets()
    }

    func configureIINA() -> URL? {
        if !isEnabled { setEnabled(true) }
        guard let bridge else { setupMessage = message; return nil }
        do {
            let package = try integrationInstaller().prepareIINA(
                configuration: bridge.configuration)
            setupMessage =
                "Bridge settings are saved. Confirm installation and permissions in IINA. "
                + "For an existing installation, approve replacement, then reload plugins or restart IINA."
            return package
        } catch { setupMessage = error.localizedDescription; return nil }
    }

    func configureChrome() -> URL? {
        if !isEnabled { setEnabled(true) }
        guard bridge != nil else { setupMessage = message; return nil }
        do {
            let folder = try integrationInstaller().installChrome()
            setupMessage =
                "Chrome helper is configured. In Chrome, enable Developer mode and Load unpacked, "
                + "then select the revealed ChromeExtension folder. Reload an existing extension and video tabs."
            return folder
        } catch { setupMessage = error.localizedDescription; return nil }
    }

    private func integrationInstaller() throws -> MediaIntegrationInstaller {
        guard let resources = Bundle.main.resourceURL else {
            throw IntegrationSetupError.missingResources
        }
        return MediaIntegrationInstaller(
            home: FileManager.default.homeDirectoryForCurrentUser,
            resources: resources.appendingPathComponent("MediaAdapters"),
            helper: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Helpers/SofaRemoteNativeHost"))
    }

    private func removeAllTargets() {
        for targetID in Array(router.targets.keys) { router.remove(targetID: targetID) }
    }
}
