import AppleCore
import Foundation

struct QueuedPlayerVolumeRequest {
    let requestID: String
    let targetID: String
    let gainRatio: Double
    let displayPercent: Double
}

@MainActor
final class LocalPointerDragCoordinator {
    private var resultPolicy = PointerDragResultPolicy()
    private var movementGate = PointerDragStartGate()
    private var activeDragID: UUID?
    private var trackedDragIDs: Set<UUID> = []
    private var queuedStartIDs: [UUID] = []
    private var queuedReleaseIDs: [UUID] = []

    func begin(trackResults: Bool, send: (RemoteCommand) -> Bool) -> UUID? {
        guard activeDragID == nil else { return nil }
        let dragID = UUID()
        activeDragID = dragID
        movementGate.begin(gestureID: dragID.uuidString)
        if trackResults {
            resultPolicy.begin(gestureID: dragID.uuidString)
            trackedDragIDs.insert(dragID)
            queuedStartIDs.append(dragID)
        } else {
            _ = movementGate.acceptStart(gestureID: dragID.uuidString)
        }
        guard send(RemoteCommand(name: .pointerButtonDown, button: .left)) else {
            activeDragID = nil
            movementGate.finish(gestureID: dragID.uuidString)
            trackedDragIDs.remove(dragID)
            queuedStartIDs.removeAll { $0 == dragID }
            resultPolicy.cancel(gestureID: dragID.uuidString)
            return nil
        }
        return dragID
    }

    func end(_ dragID: UUID, send: (RemoteCommand) -> Bool) {
        guard activeDragID == dragID else { return }
        activeDragID = nil
        movementGate.finish(gestureID: dragID.uuidString)
        if trackedDragIDs.contains(dragID) {
            resultPolicy.expectRelease(gestureID: dragID.uuidString)
            queuedReleaseIDs.append(dragID)
        }
        _ = send(RemoteCommand(name: .pointerButtonUp, button: .left))
    }

    func permitsMovement(for dragID: UUID) -> Bool {
        activeDragID == dragID && movementGate.permitsMovement(gestureID: dragID.uuidString)
    }

    func registerDispatchedCommand(_ command: RemoteCommand, requestID: String) {
        if command.name == .pointerButtonDown, !queuedStartIDs.isEmpty {
            let dragID = queuedStartIDs.removeFirst()
            resultPolicy.registerStart(gestureID: dragID.uuidString, requestID: requestID)
        } else if command.name == .pointerButtonUp, !queuedReleaseIDs.isEmpty {
            let dragID = queuedReleaseIDs.removeFirst()
            resultPolicy.registerRelease(gestureID: dragID.uuidString, requestID: requestID)
        }
    }

    func acceptResult(requestID: String, succeeded: Bool) -> PointerDragResultPolicy.Outcome? {
        let outcome = resultPolicy.acceptResult(requestID: requestID, succeeded: succeeded)
        switch outcome {
        case let .startAccepted(gestureID)?:
            _ = movementGate.acceptStart(gestureID: gestureID)
        case let .startRejected(gestureID)?:
            _ = movementGate.rejectStart(gestureID: gestureID)
            if let dragID = UUID(uuidString: gestureID) {
                if activeDragID == dragID { activeDragID = nil }
                if !resultPolicy.contains(gestureID: gestureID) { trackedDragIDs.remove(dragID) }
            }
        case let .releaseAccepted(gestureID)?,
            let .releaseFailureSuppressed(gestureID)?,
            let .releaseFailureRequiresSessionTeardown(gestureID)?:
            movementGate.finish(gestureID: gestureID)
            if let dragID = UUID(uuidString: gestureID) { trackedDragIDs.remove(dragID) }
        default:
            break
        }
        return outcome
    }

    func reset() {
        resultPolicy.reset()
        movementGate.reset()
        activeDragID = nil
        trackedDragIDs.removeAll(keepingCapacity: true)
        queuedStartIDs.removeAll(keepingCapacity: true)
        queuedReleaseIDs.removeAll(keepingCapacity: true)
    }
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
            self?.send(command) ?? false
        }
    }

    @discardableResult
    func sendLocalPointerDragMove(_ dragID: UUID, x: Double, y: Double) -> Bool {
        guard localPointerDragCoordinator.permitsMovement(for: dragID) else { return false }
        return send(RemoteCommand(name: .pointerMove, x: x, y: y))
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
