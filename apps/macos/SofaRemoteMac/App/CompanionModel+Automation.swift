import AppKit
import AppleCore
import MacSupport

extension CompanionModel {
    func startLocalAutomation() {
        let server = LocalAutomationServer { [weak self] request, deadline in
            await self?.handleLocalAutomation(request, deadline: deadline)
                ?? LocalAutomationResponse(.unavailable)
        }
        do {
            try server.start()
            automationServer = server
        } catch {
            errorMessage = "Local automation unavailable: \(error.localizedDescription)"
        }
    }

    private func handleLocalAutomation(
        _ request: LocalAutomationRequest, deadline: ContinuousClock.Instant
    ) -> LocalAutomationResponse {
        numericPairing?.tick()
        webRemote.refreshPairing()
        let locked = sessionDisplay.sessionLocked
        let unlocked = locked == false
        let router = LocalAutomationRouter(
            controls: localControls(unlocked: unlocked), values: localStatus(locked: locked),
            unlocked: unlocked,
            readValue: { [weak self] control in
                switch control {
                case .numericCode: self?.numericPairingPrompt?.code
                case .webPairingCode: self?.webRemote.pairingPrompt?.code
                default: nil
                }
            },
            invoke: { [weak self] request in self?.invokeLocalControl(request) })
        return router.handle(request, deadline: deadline)
    }

    // An exhaustive typed allowlist; each case delegates to the existing UI controller.
    // swiftlint:disable:next cyclomatic_complexity
    private func invokeLocalControl(_ request: LocalAutomationRequest) {
        guard let control = request.control else { return }
        switch control {
        case .accessibilityRequest: desktop.requestAccessibility()
        case .mediaEnabled: setMediaBridgeEnabled(request.value == "true")
        case .mediaSetupIINA: mediaAdapters.setUpIINA()
        case .mediaSetupChrome: mediaAdapters.setUpChrome()
        case .mediaManualExpanded: mediaAdapters.manualSetupExpanded = request.value == "true"
        case .mediaCopyToken: mediaAdapters.copyToken()
        case .unlockManage: unlockController.manage(uninstall: false)
        case .unlockUninstall: unlockController.manage(uninstall: true)
        case .unlockEnabled: unlockController.setEnabled(request.value == "true")
        case .deviceUnlock:
            if let id = request.deviceID {
                unlockController.setDevice(id, allowed: request.value == "true")
            }
        case .deviceRemove:
            if let device = pairedDevices.first(where: { $0.id == request.deviceID }) {
                revoke(device)
            }
        case .recoveryChooseSetup:
            if let path = request.path {
                phoneRecovery.configure(from: URL(fileURLWithPath: path))
            } else {
                Task { @MainActor [weak self] in self?.phoneRecovery.chooseSetup() }
            }
        case .recoveryReinstall: phoneRecovery.reinstall()
        case .webEnabled: webRemote.setEnabled(request.value == "true")
        case .webOpen: webRemote.openInBrowser()
        case .webCopyURL: webRemote.copyURL()
        case .webOpenFolder: webRemote.openFolder()
        case .webReload: webRemote.reload()
        case .qrOpen: openPairing()
        case .qrClose: closePairing()
        case .qrCopy: copyInvitation()
        case .numericCancel: numericPairing?.cancel()
        case .webPairingCancel: webRemote.cancelPairing()
        case .numericCode, .webPairingCode: break
        case .appQuit:
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func copyInvitation() {
        guard let invitation else { return }
        CompanionClipboard.copy(invitation, concealed: true)
    }

    private func localStatus(locked: Bool?) -> [String: String] {
        var values = [
            "summary": summary, "connectedCount": String(connectedCount), "bleStatus": bleStatus,
            "accessibilityGranted": String(remoteState.accessibilityGranted),
            "probeCount": String(probeCount),
            "sessionLocked": locked.map { String($0) } ?? "unknown",
            "media.message": mediaAdapters.message,
            "media.enabled": String(mediaAdapters.isEnabled),
            "media.running": String(mediaAdapters.isRunning),
            "unlock.message": unlockController.message,
            "unlock.busy": String(unlockController.isBusy),
            "unlock.installed": String(unlockController.installed),
            "unlock.enabled": String(unlockController.enabled),
            "unlock.needsUpdate": String(unlockController.needsUpdate),
            "unlock.reachable": String(unlockController.reachable),
            "recovery.message": phoneRecovery.message,
            "recovery.configured": String(phoneRecovery.configured),
            "recovery.busy": String(phoneRecovery.isBusy),
            "web.status": webRemote.status, "web.dnsStatus": webRemote.dnsStatus,
            "web.busy": String(webRemote.busy), "web.enabled": String(webRemote.enabled)
        ]
        values["error"] = errorMessage
        values["lastProbeProcessingMilliseconds"] = lastProbeProcessingMilliseconds.map {
            String($0)
        }
        values["systemVolumeReason"] = remoteState.systemVolumeReason
        values["media.setupMessage"] = mediaAdapters.setupMessage
        values["media.port"] = mediaAdapters.port.map { String($0) }
        values["web.address"] = webRemote.address?.absoluteString
        values["web.error"] = webRemote.errorMessage
        values["pairing.qr.expiresAt"] = invitationExpiresAt?.ISO8601Format()
        values["pairing.numeric.deviceName"] = numericPairingPrompt?.deviceName
        values["pairing.numeric.remainingAttempts"] = numericPairingPrompt.map {
            String($0.remainingAttempts)
        }
        values["pairing.web.deviceName"] = webRemote.pairingPrompt?.deviceName
        return values
    }
}

enum CompanionClipboard {
    static func copy(_ value: String, concealed: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        if concealed {
            NSPasteboard.general.setData(
                Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}
