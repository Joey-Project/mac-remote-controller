import Foundation

/// A bounded FIFO that sums adjacent pointer deltas while preserving control barriers.
public struct InputCommandScheduler: Sendable {
    public let capacity: Int
    private(set) public var queuedCommands: [RemoteCommand] = []
    private var protectedPrefixCount = 0

    public init(capacity: Int = 8) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Pointer deltas are best-effort when a discrete barrier fills the bounded queue.
    public static func isBestEffortPointerDelta(_ command: RemoteCommand) -> Bool {
        command.name == .pointerMove || command.name == .pointerScroll
    }

    /// Enqueues a validated command. On overflow, only motion after the last
    /// discrete barrier may be discarded; accepted barriers and their preceding
    /// motion remain in order.
    @discardableResult
    public mutating func enqueue(_ command: RemoteCommand, preservingMotion: Bool = false) -> Bool {
        guard (try? command.validate()) != nil else { return false }

        if command.name == .systemVolumeSet,
            let index = queuedCommands.lastIndex(where: { $0.name == .systemVolumeSet }),
            index == queuedCommands.count - 1
        {
            queuedCommands[index] = command
            return true
        }

        if isMotion(command), let last = queuedCommands.last, last.name == command.name,
            let combined = combinedMotion(last, command)
        {
            queuedCommands[queuedCommands.count - 1] = combined
            if preservingMotion { protectedPrefixCount = queuedCommands.count }
            return true
        }

        if queuedCommands.count == capacity, !preservingMotion {
            if isMotion(command) || command.name == .systemVolumeSet {
                discardTrailingMotion()
            }
        }
        guard queuedCommands.count < capacity else { return false }
        queuedCommands.append(command)
        if preservingMotion { protectedPrefixCount = queuedCommands.count }
        return true
    }

    public mutating func dequeue(maximumCount: Int) -> [RemoteCommand] {
        guard maximumCount > 0 else { return [] }
        let count = min(maximumCount, queuedCommands.count)
        let commands = Array(queuedCommands.prefix(count))
        queuedCommands.removeFirst(count)
        protectedPrefixCount = max(0, protectedPrefixCount - count)
        return commands
    }

    public mutating func reset() {
        queuedCommands.removeAll(keepingCapacity: true)
        protectedPrefixCount = 0
    }

    private func isMotion(_ command: RemoteCommand) -> Bool {
        Self.isBestEffortPointerDelta(command)
    }

    private func isBarrier(_ command: RemoteCommand) -> Bool {
        !isMotion(command) && command.name != .systemVolumeSet
    }

    private mutating func discardTrailingMotion() {
        let barrierEnd = queuedCommands.lastIndex(where: isBarrier).map { $0 + 1 } ?? 0
        let start = max(barrierEnd, protectedPrefixCount)
        let indices = queuedCommands[start...].indices.filter { isMotion(queuedCommands[$0]) }
        for index in indices.reversed() { queuedCommands.remove(at: index) }
    }

    private func combinedMotion(_ first: RemoteCommand, _ second: RemoteCommand)
        -> RemoteCommand?
    {
        let limit = first.name == .pointerMove ? 500.0 : 100.0
        guard let x = first.x, let y = first.y, let nextX = second.x, let nextY = second.y else {
            return nil
        }
        let totalX = x + nextX
        let totalY = y + nextY
        guard abs(totalX) <= limit, abs(totalY) <= limit else { return nil }
        return RemoteCommand(name: first.name, x: totalX, y: totalY)
    }
}
