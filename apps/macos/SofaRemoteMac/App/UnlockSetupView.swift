import SwiftUI

struct UnlockSetupView: View {
    @Bindable var controller: UnlockController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote unlock").font(.headline)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if controller.installed, controller.reachable, !controller.needsUpdate {
                Toggle(
                    "Enable remote unlock",
                    isOn: Binding(
                        get: { controller.enabled }, set: { controller.setEnabled($0) }))
            } else {
                Button(setupLabel) {
                    controller.manage(uninstall: false)
                }
            }
            if controller.installed {
                Button("Uninstall Unlock Helper…", role: .destructive) {
                    controller.manage(uninstall: true)
                }
            }
            Text("Unlocks an existing logged-in session. Allow individual paired devices below.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(controller.isBusy)
    }

    private var setupLabel: String {
        if controller.needsUpdate { return "Update Unlock Helper…" }
        return controller.installed ? "Repair Unlock Helper…" : "Install Unlock Helper…"
    }
}
