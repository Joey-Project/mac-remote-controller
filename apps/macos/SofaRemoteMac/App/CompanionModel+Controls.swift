import Foundation
import MacSupport

extension CompanionModel {
    func localControls(unlocked: Bool) -> [LocalControlDescriptor] {
        CompanionControl.allCases.flatMap { control -> [LocalControlDescriptor] in
            var descriptors = controlDescriptors(control)
            for index in descriptors.indices {
                descriptors[index].enabled = descriptors[index].enabled && unlocked
            }
            return descriptors
        }
    }

    // Keep this declarative catalog exhaustive so a new control needs an explicit UI mapping.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func controlDescriptors(_ control: CompanionControl) -> [LocalControlDescriptor] {
        let media = mediaAdapters
        let unlock = unlockController
        let web = webRemote
        let manualVisible = media.isEnabled && media.token != nil && media.port != nil
        let unlockReady = unlock.installed && unlock.reachable && !unlock.needsUpdate
        switch control {
        case .accessibilityRequest:
            return [
                .init(
                    control, "Allow Accessibility…", visible: !remoteState.accessibilityGranted,
                    requiresSystemInteraction: true)
            ]
        case .mediaEnabled:
            return [
                .init(
                    control, "Enable local media adapters", kind: .toggle,
                    value: String(media.isEnabled))
            ]
        case .mediaSetupIINA:
            return [.init(control, "Set Up IINA", requiresSystemInteraction: true)]
        case .mediaSetupChrome:
            return [.init(control, "Set Up Chrome", requiresSystemInteraction: true)]
        case .mediaManualExpanded:
            return [
                .init(
                    control, "Manual setup", kind: .disclosure, visible: manualVisible,
                    value: String(media.manualSetupExpanded))
            ]
        case .mediaCopyToken:
            return [
                .init(
                    control, "Copy token for IINA setup",
                    visible: manualVisible && media.manualSetupExpanded)
            ]
        case .unlockManage:
            let label =
                unlock.needsUpdate
                ? "Update Unlock Helper…"
                : unlock.installed ? "Repair Unlock Helper…" : "Install Unlock Helper…"
            return [
                .init(
                    control, label, visible: !unlockReady, enabled: !unlock.isBusy,
                    requiresSystemInteraction: true)
            ]
        case .unlockUninstall:
            return [
                .init(
                    control, "Uninstall Unlock Helper…", visible: unlock.installed,
                    enabled: !unlock.isBusy, requiresSystemInteraction: true)
            ]
        case .unlockEnabled:
            return [
                .init(
                    control, "Enable remote unlock", kind: .toggle,
                    visible: unlockReady, enabled: !unlock.isBusy, value: String(unlock.enabled))
            ]
        case .deviceUnlock, .deviceRemove:
            guard !pairedDevices.isEmpty else {
                return [
                    .init(control, control == .deviceUnlock ? "Unlock" : "Remove", visible: false)
                ]
            }
            return pairedDevices.map { device in
                .init(
                    control, "\(control == .deviceUnlock ? "Unlock" : "Remove") · \(device.name)",
                    kind: control == .deviceUnlock ? .toggle : .button,
                    enabled: control == .deviceRemove || (unlock.reachable && !unlock.isBusy),
                    value: control == .deviceUnlock
                        ? String(unlock.allowedDeviceIDs.contains(device.id)) : nil,
                    deviceID: device.id)
            }
        case .recoveryChooseSetup:
            return [
                .init(
                    control, "Choose Renewal Setup…", enabled: !phoneRecovery.isBusy,
                    requiresSystemInteraction: true)
            ]
        case .recoveryReinstall:
            return [
                .init(
                    control, "Re-sign & Reinstall…", visible: phoneRecovery.configured,
                    enabled: !phoneRecovery.isBusy)
            ]
        case .webEnabled:
            return [
                .init(
                    control, "Enable Web remote", kind: .toggle, visible: web.hasConfiguration,
                    enabled: !web.busy, value: String(web.enabled))
            ]
        case .webOpen:
            return [.init(control, "Open in browser", visible: web.address != nil)]
        case .webCopyURL:
            return [.init(control, "Copy URL", visible: web.address != nil)]
        case .webOpenFolder:
            return [.init(control, "Web setup folder…")]
        case .webReload:
            return [.init(control, "Reload setup", enabled: !web.busy)]
        case .qrOpen:
            return [.init(control, "Use QR pairing instead…", visible: invitation == nil)]
        case .qrClose:
            return [.init(control, "Close pairing", visible: invitation != nil)]
        case .qrCopy:
            return [.init(control, "Copy invitation", visible: invitation != nil)]
        case .numericCancel:
            return [.init(control, "Cancel pairing", visible: numericPairingPrompt != nil)]
        case .numericCode:
            return [
                .init(control, "Pairing code", kind: .value, visible: numericPairingPrompt != nil)
            ]
        case .webPairingCancel:
            return [.init(control, "Cancel pairing", visible: web.pairingPrompt != nil)]
        case .webPairingCode:
            return [.init(control, "Pairing code", kind: .value, visible: web.pairingPrompt != nil)]
        case .appQuit:
            return [.init(control, "Quit Sofa Remote")]
        }
    }
}
