import AppleCore
import Foundation

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
}
