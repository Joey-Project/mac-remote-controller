import AppleCore
import Foundation

struct QueuedPlayerVolumeRequest {
    let requestID: String
    let targetID: String
    let gainRatio: Double
    let displayPercent: Double
}

extension RemoteModel {
    func benchmarkSummary(_ report: RTTBenchmarkReport) -> String {
        report.summary
    }

    func beginLocalPointerDrag() -> UUID? {
        var trackResults = true
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting { trackResults = false }
        #endif
        let sendCommand: (RemoteCommand) -> Bool = { [weak self] command in
            self?.send(command) ?? false
        }
        return localPointerDragCoordinator.begin(
            trackResults: trackResults, send: sendCommand)
    }

    func endLocalPointerDrag(_ dragID: UUID) {
        localPointerDragCoordinator.end(dragID) { [weak self] command in
            self?.send(command, orderedDragInput: true) ?? false
        }
    }

    @discardableResult
    func sendLocalPointerDragMove(_ dragID: UUID, x: Double, y: Double) -> Bool {
        localPointerDragCoordinator.move(dragID, x: x, y: y) { [weak self] command in
            self?.send(command, orderedDragInput: true) ?? false
        }
    }

    func resolveLocalPointerDragResult(
        requestID: String, succeeded: Bool
    ) -> PointerDragResultPolicy.Outcome? {
        let outcome = localPointerDragCoordinator.acceptResult(
            requestID: requestID, succeeded: succeeded)
        if case let .startRejected(gestureID)? = outcome {
            rejectedLocalDragID = UUID(uuidString: gestureID)
        }
        return outcome
    }

    func requiresSafePointerTeardown(
        metadata: PendingCommandMetadata, message: WireMessage
    ) -> Bool {
        let outcome = resolveLocalPointerDragResult(
            requestID: metadata.requestID, succeeded: message.error == nil)
        switch outcome {
        case .some(.releaseFailureDeferred), .some(.releaseFailureSuppressed):
            return false
        case .some(.releaseFailureRequiresSessionTeardown):
            return true
        default:
            return metadata.requiresSessionTeardown(for: message)
        }
    }

    func resetLocalDragTracking() {
        localPointerDragCoordinator.reset()
        rejectedLocalDragID = nil
    }

    func scheduleCoalescedFlush() {
        guard coalescingTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coalescingTimer = nil
                self?.flushQueuedCommands()
            }
        }
        coalescingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func flushQueuedCommands() {
        guard let connectionID, let peer else { return }
        let available = max(0, 8 - pending.count)
        for command in commandScheduler.dequeue(maximumCount: available) {
            sequence += 1
            let requestID = UUID().uuidString
            pending[requestID] = (
                metadata: PendingCommandMetadata(
                    connectionID: connectionID, requestID: requestID,
                    sequence: sequence, command: command),
                sent: ContinuousClock.now
            )
            if command.name == .mediaControl,
                command.mediaRequest?.action == .setVolume,
                !queuedPlayerVolumeRequests.isEmpty
            {
                pendingPlayerVolumeRequests[requestID] = queuedPlayerVolumeRequests.removeFirst()
            }
            localPointerDragCoordinator.registerDispatchedCommand(command, requestID: requestID)
            peer.send(
                WireMessage(
                    type: .command, connectionID: connectionID, requestID: requestID,
                    sequence: sequence, command: command))
        }
        localPointerDragCoordinator.resume { [weak self] command in
            self?.send(command, orderedDragInput: true) ?? false
        }
    }
}

extension RemoteModel {
    func handleQueueRejection(_ command: RemoteCommand, orderedDragInput: Bool) -> Bool {
        if orderedDragInput { return false }
        if command.name == .pointerButtonUp {
            let unknownOutcome = !pending.isEmpty
            disconnect()
            errorMessage =
                unknownOutcome
                ? "Disconnected to release the pointer safely. "
                    + "A pending control may have taken effect; it was not retried."
                : "Disconnected to release the pointer safely. "
                    + "Reconnect to continue."
        } else if !InputCommandScheduler.isBestEffortPointerDelta(command) {
            errorMessage = "The Mac is busy. Wait for the pending controls to finish."
        }
        return false
    }

    func recordPlayerVolumeResult(requestID: String, succeeded: Bool) {
        guard let request = pendingPlayerVolumeRequests.removeValue(forKey: requestID),
            var displayState = playerVolumeDisplayStates[request.targetID]
        else { return }
        displayState.complete(
            targetID: request.targetID, requestID: request.requestID,
            value: request.displayPercent, succeeded: succeeded)
        playerVolumeDisplayStates[request.targetID] = displayState
    }

    @discardableResult
    func sendPlayerVolume(
        targetID: String, gainRatio: Double, displayPercent: Double, requestID: String
    ) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if isUITesting {
                return send(
                    RemoteCommand(
                        name: .mediaControl,
                        mediaRequest: MediaRequest(
                            targetID: targetID, action: .setVolume, value: gainRatio)))
            }
        #endif
        guard let maximumPercent = currentPlayerVolumeMaximumPercent(targetID: targetID) else {
            return false
        }
        queuedPlayerVolumeRequests.append(
            QueuedPlayerVolumeRequest(
                requestID: requestID, targetID: targetID, gainRatio: gainRatio,
                displayPercent: displayPercent))
        let accepted = send(
            RemoteCommand(
                name: .mediaControl,
                mediaRequest: MediaRequest(
                    targetID: targetID, action: .setVolume, value: gainRatio)))
        if !accepted,
            let index = queuedPlayerVolumeRequests.firstIndex(where: {
                $0.requestID == requestID
            })
        {
            queuedPlayerVolumeRequests.remove(at: index)
        } else if accepted {
            var displayState =
                playerVolumeDisplayStates[targetID]
                ?? PlayerVolumeDisplayState(
                    targetID: targetID, maximum: maximumPercent,
                    remoteValue: currentPlayerVolumePercent(targetID: targetID))
            displayState.configure(
                targetID: targetID, maximum: maximumPercent,
                remoteValue: currentPlayerVolumePercent(targetID: targetID), isConnected: true)
            displayState.request(id: requestID, value: displayPercent, wasAccepted: true)
            playerVolumeDisplayStates[targetID] = displayState
        }
        return accepted
    }

    func reconcilePlayerVolumeDisplayStates(with state: RemoteState) {
        for targetID in Array(playerVolumeDisplayStates.keys) {
            guard let target = state.mediaTargets?.first(where: { $0.id == targetID }),
                let maximumGainRatio = target.capabilities.playerVolumeMaximum,
                let maximum = PlayerVolumePolicy.uiMaximumPercent(fromGainRatio: maximumGainRatio),
                let playerVolume = target.playerVolume,
                let remoteValue = PlayerVolumePolicy.uiPercent(
                    fromGainRatio: playerVolume, maximumGainRatio: maximumGainRatio)
            else {
                playerVolumeDisplayStates.removeValue(forKey: targetID)
                continue
            }
            var displayState = playerVolumeDisplayStates[targetID]
            displayState?.configure(
                targetID: targetID, maximum: maximum, remoteValue: remoteValue,
                isConnected: true)
            if let displayState { playerVolumeDisplayStates[targetID] = displayState }
        }
    }

    private func currentPlayerVolumePercent(targetID: String) -> Double? {
        guard let target = remoteState?.mediaTargets?.first(where: { $0.id == targetID }),
            let maximumGainRatio = target.capabilities.playerVolumeMaximum,
            let playerVolume = target.playerVolume
        else { return nil }
        return PlayerVolumePolicy.uiPercent(
            fromGainRatio: playerVolume, maximumGainRatio: maximumGainRatio)
    }

    private func currentPlayerVolumeMaximumPercent(targetID: String) -> Double? {
        guard
            let maximumGainRatio = remoteState?.mediaTargets?.first(where: {
                $0.id == targetID
            })?.capabilities.playerVolumeMaximum
        else { return nil }
        return PlayerVolumePolicy.uiMaximumPercent(fromGainRatio: maximumGainRatio)
    }
}
