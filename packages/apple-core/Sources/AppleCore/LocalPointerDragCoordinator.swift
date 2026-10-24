import Foundation

/// Orders acknowledged drag movement and release before later user input.
@MainActor
public final class LocalPointerDragCoordinator {
    private struct Motion {
        let id: UUID
        var x = 0.0
        var y = 0.0
        var releaseRequested = false
    }

    private var resultPolicy = PointerDragResultPolicy()
    private var movementGate = PointerDragStartGate()
    private var motion: Motion?
    private var activeDragID: UUID?
    private var trackedDragIDs: Set<UUID> = []
    private var queuedStartIDs: [UUID] = []
    private var queuedReleaseIDs: [UUID] = []
    private var deferredCommands = InputCommandScheduler()
    private var isDraining = false

    public init() {}

    public func begin(trackResults: Bool, send: (RemoteCommand) -> Bool) -> UUID? {
        guard motion == nil, deferredCommands.queuedCommands.isEmpty else { return nil }
        let dragID = UUID()
        activeDragID = dragID
        motion = Motion(id: dragID)
        movementGate.begin(gestureID: dragID.uuidString)
        if trackResults {
            resultPolicy.begin(gestureID: dragID.uuidString)
            trackedDragIDs.insert(dragID)
            queuedStartIDs.append(dragID)
        } else {
            _ = movementGate.acceptStart(gestureID: dragID.uuidString)
        }
        guard send(RemoteCommand(name: .pointerButtonDown, button: .left)) else {
            discardMotion(dragID)
            trackedDragIDs.remove(dragID)
            queuedStartIDs.removeAll { $0 == dragID }
            resultPolicy.cancel(gestureID: dragID.uuidString)
            return nil
        }
        return dragID
    }

    @discardableResult
    public func move(_ dragID: UUID, x: Double, y: Double, send: (RemoteCommand) -> Bool) -> Bool {
        guard activeDragID == dragID, var motion, motion.id == dragID,
            x.isFinite, y.isFinite, abs(x) <= 500, abs(y) <= 500,
            abs(motion.x + x) <= 1_000_000, abs(motion.y + y) <= 1_000_000
        else { return false }
        motion.x += x
        motion.y += y
        self.motion = motion
        resume(send: send)
        return true
    }

    public func end(_ dragID: UUID, send: (RemoteCommand) -> Bool) {
        guard activeDragID == dragID, motion?.id == dragID else { return }
        activeDragID = nil
        motion?.releaseRequested = true
        if trackedDragIDs.contains(dragID) {
            resultPolicy.expectRelease(gestureID: dragID.uuidString)
        }
        resume(send: send)
    }

    /// Returns nil when ordinary input can bypass this coordinator.
    public func deferCommandIfNeeded(_ command: RemoteCommand) -> Bool? {
        guard motion?.releaseRequested == true || !deferredCommands.queuedCommands.isEmpty else {
            return nil
        }
        return deferredCommands.enqueue(command)
    }

    /// Called after acknowledgements and after the transport queue gains room.
    public func resume(send: (RemoteCommand) -> Bool) {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        if let motion {
            guard movementGate.permitsMovement(gestureID: motion.id.uuidString),
                drainMovement(motion.id, send: send)
            else { return }
            if self.motion?.releaseRequested == true {
                guard enqueueRelease(motion.id, send: send) else { return }
            }
        }
        guard motion == nil else { return }
        while let command = deferredCommands.queuedCommands.first {
            guard send(command) else { return }
            _ = deferredCommands.dequeue(maximumCount: 1)
        }
    }

    private func drainMovement(_ dragID: UUID, send: (RemoteCommand) -> Bool) -> Bool {
        // Bound one drain to the transport scheduler's capacity. Remaining motion
        // stays in two scalars and is retried when queued commands are dispatched.
        for _ in 0..<8 {
            guard let motion, motion.id == dragID else { return false }
            if motion.x == 0, motion.y == 0 { return true }
            let x = min(500, max(-500, motion.x))
            let y = min(500, max(-500, motion.y))
            guard send(RemoteCommand(name: .pointerMove, x: x, y: y)),
                self.motion?.id == dragID
            else { return false }
            self.motion?.x -= x
            self.motion?.y -= y
        }
        return motion?.x == 0 && motion?.y == 0
    }

    private func enqueueRelease(_ dragID: UUID, send: (RemoteCommand) -> Bool) -> Bool {
        let tracked = trackedDragIDs.contains(dragID)
        if tracked { queuedReleaseIDs.append(dragID) }
        guard send(RemoteCommand(name: .pointerButtonUp, button: .left)) else {
            queuedReleaseIDs.removeAll { $0 == dragID }
            return false
        }
        discardMotion(dragID)
        return true
    }

    public func registerDispatchedCommand(_ command: RemoteCommand, requestID: String) {
        if command.name == .pointerButtonDown, !queuedStartIDs.isEmpty {
            let dragID = queuedStartIDs.removeFirst()
            resultPolicy.registerStart(gestureID: dragID.uuidString, requestID: requestID)
        } else if command.name == .pointerButtonUp, !queuedReleaseIDs.isEmpty {
            let dragID = queuedReleaseIDs.removeFirst()
            resultPolicy.registerRelease(gestureID: dragID.uuidString, requestID: requestID)
        }
    }

    public func acceptResult(
        requestID: String, succeeded: Bool
    ) -> PointerDragResultPolicy.Outcome? {
        let outcome = resultPolicy.acceptResult(requestID: requestID, succeeded: succeeded)
        switch outcome {
        case let .startAccepted(gestureID)?:
            _ = movementGate.acceptStart(gestureID: gestureID)
        case let .startRejected(gestureID)?:
            if let dragID = UUID(uuidString: gestureID) {
                discardMotion(dragID)
                trackedDragIDs.remove(dragID)
                resultPolicy.cancel(gestureID: gestureID)
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

    private func discardMotion(_ dragID: UUID) {
        if motion?.id == dragID { motion = nil }
        if activeDragID == dragID { activeDragID = nil }
        movementGate.finish(gestureID: dragID.uuidString)
    }

    public func reset() {
        resultPolicy.reset()
        movementGate.reset()
        motion = nil
        activeDragID = nil
        trackedDragIDs.removeAll(keepingCapacity: true)
        queuedStartIDs.removeAll(keepingCapacity: true)
        queuedReleaseIDs.removeAll(keepingCapacity: true)
        deferredCommands.reset()
    }
}
