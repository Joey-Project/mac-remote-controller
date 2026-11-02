import Darwin
import Foundation
import UnlockNative

/// Confined to the broker's serial queue. No polling runs when there is no request.
final class UnlockTransactions: @unchecked Sendable {
    struct Active {
        let identifier: String
        let peer: UUID
        let session: Data
        let user: UInt32
        let deadline: TimeInterval
        var waiter: ((Data) -> Void)?
    }

    struct Completion {
        let identifier: String
        let peer: UUID
        let response: Data
        let expires: TimeInterval
    }

    let queue: DispatchQueue
    private var active: Active?
    private var timer: DispatchSourceTimer?
    private var lease: Int32 = -1
    private var completion: Completion?

    init(queue: DispatchQueue) { self.queue = queue }

    func begin(peer: UUID, device: String, clientUID: UInt32) throws -> UnlockResponse {
        guard active == nil else { throw UnlockFailure.busy }
        let state = try eligibleConsole(device: device, clientUID: clientUID)
        try arm(state)
        let identifier = UUID().uuidString
        let now = SRContinuousTime()
        guard now.isFinite else { close(lease); lease = -1; throw UnlockFailure.grantRefused }
        active = Active(
            identifier: identifier, peer: peer, session: fingerprint(state), user: clientUID,
            deadline: now + 8)
        completion = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.observe() }
        self.timer = timer
        timer.resume()
        var response = UnlockResponse()
        response.outcome = "armed"
        response.transactionID = identifier
        return response
    }

    private func eligibleConsole(device: String, clientUID: UInt32) throws -> SRConsoleSnapshot {
        let settings = try UnlockSettings.load()
        let record = try UnlockInstallationRecord.load()
        guard record.phase == "installed" else { throw UnlockFailure.notInstalled }
        guard settings.enabled else { throw UnlockFailure.notEnabled }
        guard settings.allowedDeviceIDs.contains(device) else { throw UnlockFailure.deviceDenied }
        guard record.activePolicy != nil,
            try UnlockPolicy.sameDefinition(
                UnlockAuthorizationDB.read(UnlockPaths.screenRight), record.activePolicy)
        else { throw UnlockFailure.conflict }
        let state = SRReadConsole()
        guard state.known, state.loggedIn else { throw UnlockFailure.consoleUnavailable }
        guard state.userID == clientUID else { throw UnlockFailure.wrongUser }
        guard state.locked else { throw UnlockFailure.notLocked }
        return state
    }

    private func arm(_ state: SRConsoleSnapshot) throws {
        lease = SRStartUnlockLease(UnlockPaths.directory.path, 0)
        guard lease >= 0 else { throw UnlockFailure.busy }
        guard SRSetUnlockEnabled(UnlockPaths.directory.path, 0, true),
            SRCreateUnlockGrant(UnlockPaths.directory.path, 0, state, SRContinuousTime())
        else {
            close(lease); lease = -1
            throw UnlockFailure.grantRefused
        }
    }

    func wait(peer: UUID, identifier: String, reply: @escaping (Data) -> Void) throws {
        if let completion, completion.identifier == identifier, completion.peer == peer,
            SRContinuousTime() < completion.expires
        {
            reply(completion.response)
            self.completion = nil
            return
        }
        guard var active, active.identifier == identifier, active.peer == peer,
            active.waiter == nil
        else { throw UnlockFailure.invalidRequest }
        active.waiter = reply
        self.active = active
    }

    func cancel(peer: UUID? = nil, identifier: String? = nil) {
        guard let active, peer == nil || active.peer == peer,
            identifier == nil || active.identifier == identifier
        else { return }
        finish(failure: .cancelled)
    }

    private func observe() {
        guard let active else { return }
        let state = SRReadConsole()
        guard state.known, state.loggedIn, state.userID == active.user,
            fingerprint(state) == active.session
        else { finish(failure: .consoleUnavailable); return }
        let now = SRContinuousTime()
        if !now.isFinite {
            finish(failure: .consoleUnavailable)
        } else if !state.locked {
            finish(failure: nil)
        } else if now >= active.deadline {
            finish(failure: .timedOut)
        }
    }

    private func finish(failure: UnlockFailure?) {
        guard let active else { return }
        self.active = nil
        timer?.cancel()
        timer = nil
        if lease >= 0 { close(lease); lease = -1 }
        _ = SRRevokeUnlockGrant(UnlockPaths.directory.path, 0)
        var response = UnlockResponse(failure: failure?.rawValue)
        response.outcome = failure == nil ? "unlocked" : "unconfirmed"
        response.transactionID = active.identifier
        response.locked = failure == nil ? false : nil
        let encoded = (try? JSONEncoder().encode(response)) ?? Data()
        if let waiter = active.waiter {
            waiter(encoded)
        } else {
            completion = Completion(
                identifier: active.identifier, peer: active.peer,
                response: encoded, expires: SRContinuousTime() + 10)
        }
    }

    private func fingerprint(_ state: SRConsoleSnapshot) -> Data {
        var state = state
        var result = withUnsafeBytes(of: &state.sessionUUID) { Data($0) }
        result.append(withUnsafeBytes(of: &state.bootUUID) { Data($0) })
        return result
    }
}
