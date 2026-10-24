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
    let router = MediaRouter()
    var onTargetsChanged: (([MediaTarget]?) -> Void)?

    private var bridge: LoopbackMediaBridge?

    var isRunning: Bool { bridge?.isRunning == true }
    var mediaTargets: [MediaTarget]? {
        guard isRunning else { return nil }
        return router.targets.values.sorted { $0.id < $1.id }
    }

    func setEnabled(_ enabled: Bool) {
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

    private func removeAllTargets() {
        for targetID in Array(router.targets.keys) { router.remove(targetID: targetID) }
    }
}
