import Foundation
import MacSupport
import Observation

@MainActor
@Observable
final class UnlockController {
    private(set) var installed = false
    private(set) var enabled = false
    private(set) var isBusy = false
    private(set) var needsUpdate = false
    private(set) var reachable = false
    private(set) var allowedDeviceIDs: [String] = []
    private(set) var message = "Remote unlock is not installed."
    var onChange: (() -> Void)?
    var pairedDeviceIDs: (() -> Set<String>)?
    private let client = UnlockServiceClient()
    private var active: (connection: UUID, transaction: String)?
    private var starting = false
    private var queuedDenials = UnlockDeviceRevocations()
    private var lastRefresh = Date.distantPast
    private var setupFailureMessage: String?

    func refreshIfDue() {
        guard !isBusy, Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        lastRefresh = Date()
        Task { await refresh() }
    }

    func refresh() async {
        do {
            let status = try UnlockPublicStatus.load()
            installed = true
            needsUpdate = try UnlockSigning.runningAppRequirement() != status.clientRequirement
            if needsUpdate {
                reachable = false
                enabled = false
                allowedDeviceIDs = []
                message = "Update the unlock helper to authorize this companion build."
            } else {
                let response = try await client.send(UnlockRequest(.status))
                apply(response)
            }
        } catch {
            reachable = false
            enabled = false
            allowedDeviceIDs = []
            var info = stat()
            if lstat(UnlockPaths.publicStatus.path, &info) != 0, errno == ENOENT {
                installed = false
                needsUpdate = false
                message = "Remote unlock is not installed."
            } else {
                installed = true
                message =
                    (error as? LocalizedError)?.errorDescription ?? "Unlock helper unavailable."
            }
        }
        if let setupFailureMessage { message = setupFailureMessage }
        onChange?()
        flushDenials()
    }

    func manage(uninstall: Bool) {
        guard !isBusy else { return }
        isBusy = true
        setupFailureMessage = nil
        message = uninstall ? "Removing unlock helper…" : "Installing unlock helper…"
        Task {
            do {
                let app = Bundle.main.bundleURL
                let expected = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/SofaRemoteMac.app")
                guard app.standardizedFileURL == expected.standardizedFileURL else {
                    throw UnlockFailure.invalidRequest
                }
                let command = try UnlockSetupCommand.script(
                    app: app,
                    clientRequirement: UnlockSigning.runningAppRequirement(), uid: getuid(),
                    uninstall: uninstall)
                client.invalidate()
                let script = UnlockSetupCommand.appleScript(command)
                let result = try await Task.detached {
                    try UnlockSystemCommand.run(
                        "/usr/bin/osascript", arguments: ["-e", script], seconds: 300)
                }.value
                guard result.status == 0 else { throw UnlockFailure.setupIncomplete }
                await refresh()
                guard uninstall ? !installed : installed && reachable && !needsUpdate else {
                    throw UnlockFailure.setupUnconfirmed
                }
                message =
                    uninstall
                    ? "Unlock helper removed. Existing lock-screen authentication restored."
                    : "Helper installed. Enable remote unlock, then allow a paired device below."
                if !uninstall { _ = ensureAccessibility() }
            } catch {
                message =
                    (error as? LocalizedError)?.errorDescription ?? "Unlock setup did not complete."
                setupFailureMessage = message
            }
            isBusy = false
            onChange?()
            flushDenials()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, !ensureAccessibility() { return }
        perform(UnlockRequest(enabled ? .enable : .disable))
    }

    func setDevice(_ identifier: String, allowed: Bool) {
        if !allowed {
            queuedDenials.request(identifier)
            flushDenials()
            return
        }
        guard !isBusy else { return }
        queuedDenials.cancel(identifier)
        perform(UnlockRequest(.allowDevice, deviceID: identifier))
    }

    func unlock(device: String, connection: UUID) async throws {
        guard active == nil, !starting else { throw UnlockFailure.busy }
        guard NativeUnlockTrigger.accessibilityGranted else {
            throw UnlockFailure.accessibilityRequired
        }
        starting = true
        defer { starting = false }
        let response = try await client.send(UnlockRequest(.begin, deviceID: device))
        guard let identifier = response.transactionID, response.outcome == "armed" else {
            throw UnlockFailure.grantRefused
        }
        active = (connection, identifier)
        defer { if active?.transaction == identifier { active = nil } }
        do {
            try Task.checkCancellation()
            try await NativeUnlockTrigger.perform()
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await client.send(
                    UnlockRequest(.wait, transactionID: identifier), timeout: 10)
            } onCancel: {
                Task { @MainActor [weak self] in
                    _ = try? await self?.client.send(
                        UnlockRequest(.cancel, transactionID: identifier))
                }
            }
            try Task.checkCancellation()
            guard result.outcome == "unlocked", result.locked == false else {
                throw UnlockFailure.unknownOutcome
            }
        } catch {
            _ = try? await client.send(UnlockRequest(.cancel, transactionID: identifier))
            throw error
        }
    }

    func cancel(connection: UUID) {
        guard let active, active.connection == connection else { return }
        self.active = nil
        Task {
            _ = try? await client.send(UnlockRequest(.cancel, transactionID: active.transaction))
        }
    }

    private func ensureAccessibility() -> Bool {
        guard NativeUnlockTrigger.requestAccessibilityIfNeeded() else {
            message = UnlockFailure.accessibilityRequired.localizedDescription
            setupFailureMessage = message
            onChange?()
            return false
        }
        return true
    }

    private func perform(_ request: UnlockRequest) {
        guard !isBusy else { return }
        isBusy = true
        setupFailureMessage = nil
        Task {
            var succeeded = false
            do {
                apply(try await client.send(request))
                if request.operation == .denyDevice, let identifier = request.deviceID,
                    queuedDenials.pending.contains(identifier)
                {
                    throw UnlockFailure.unknownOutcome
                }
                succeeded = true
            } catch {
                message =
                    (error as? LocalizedError)?.errorDescription
                    ?? "Unlock settings were not changed."
            }
            isBusy = false
            onChange?()
            if succeeded { flushDenials() }
        }
    }

    private func flushDenials() {
        guard installed, reachable, !needsUpdate, !isBusy,
            let identifier = queuedDenials.next
        else { return }
        perform(UnlockRequest(.denyDevice, deviceID: identifier))
    }

    private func apply(_ response: UnlockResponse) {
        reachable = true
        installed = response.installed
        enabled = response.enabled
        allowedDeviceIDs = response.allowedDeviceIDs
        queuedDenials.reconcile(
            allowed: Set(response.allowedDeviceIDs), paired: pairedDeviceIDs?())
        needsUpdate = false
        message =
            enabled
            ? "Remote unlock is enabled for selected paired devices." : "Remote unlock is off."
    }
}
