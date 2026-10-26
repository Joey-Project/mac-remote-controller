import AppleCore
import Foundation
import MacSupport

extension CompanionModel {
    func receiveProbe(_ message: WireMessage, client: ClientConnection, session: ServerSession) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard message.connectionID == session.connectionID,
            let requestID = message.requestID, let sequence = message.sequence
        else { client.peer.close(); return }
        client.peer.send(
            WireMessage(
                type: .pong, connectionID: session.connectionID,
                requestID: requestID, sequence: sequence))
        lastProbeProcessingMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        probeCount += 1
    }

    func sendState(_ state: RemoteState, to client: ClientConnection) {
        guard let session = client.session else { return }
        client.peer.send(
            WireMessage(
                type: .state, connectionID: session.connectionID, state: stateForClient(state)))
    }

    func stateForClient(_ state: RemoteState) -> RemoteState {
        var state = state
        state.capabilities = [WireCapabilities.roundTripProbe]
        return state
    }

    func startMediaCommand(
        _ accepted: AcceptedCommand,
        request: MediaRequest,
        session: ServerSession,
        client: ClientConnection,
        id: UUID
    ) {
        let routedID = "\(session.connectionID):\(accepted.requestID)"
        let task = Task { @MainActor [weak self, weak client] in
            var failure: RemoteError?
            do {
                guard let self, self.mediaAdapters.isRunning else {
                    throw MediaRouteError.targetUnavailable
                }
                try await self.mediaAdapters.router.execute(
                    request, requestID: routedID, sessionID: session.connectionID)
            } catch {
                failure = RemoteError(
                    code: "media_unavailable", message: error.localizedDescription)
            }
            guard let self, let client, self.clients[id] === client,
                client.session?.connectionID == session.connectionID
            else { return }
            client.pendingMediaTasks.removeValue(forKey: accepted.requestID)
            client.peer.send(session.makeResult(for: accepted, error: failure))
            self.remoteState.mediaTargets = self.mediaAdapters.mediaTargets
            self.sendState(self.remoteState, to: client)
        }
        client.pendingMediaTasks[accepted.requestID] = task
    }
}
