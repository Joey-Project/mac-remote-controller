import Foundation

/// Paces continuous input from its last dispatch, rather than delaying each new burst.
public struct InputCommandDispatcher: Sendable {
    private var scheduler: InputCommandScheduler
    private let interval: Duration
    private var nextContinuousFlush: ContinuousClock.Instant?

    public init(capacity: Int = 8, interval: Duration = .nanoseconds(16_666_667)) {
        precondition(interval > .zero)
        scheduler = InputCommandScheduler(capacity: capacity)
        self.interval = interval
    }

    public var queuedCommands: [RemoteCommand] { scheduler.queuedCommands }

    @discardableResult
    public mutating func enqueue(_ command: RemoteCommand, preservingMotion: Bool = false) -> Bool {
        scheduler.enqueue(command, preservingMotion: preservingMotion)
    }

    /// No timer is needed while idle or while all acknowledgement credits are occupied.
    public func flushDelay(
        at now: ContinuousClock.Instant, maximumCount: Int
    ) -> Duration? {
        guard maximumCount > 0, !queuedCommands.isEmpty else { return nil }
        // A click, key, or drag release must also flush its preceding motion in order.
        if queuedCommands.contains(where: { !Self.isContinuous($0) }) { return .zero }
        guard let nextContinuousFlush else { return .zero }
        return max(.zero, now.duration(to: nextContinuousFlush))
    }

    public mutating func dequeue(
        maximumCount: Int, at now: ContinuousClock.Instant
    ) -> [RemoteCommand] {
        guard flushDelay(at: now, maximumCount: maximumCount) == .zero else { return [] }
        let commands = scheduler.dequeue(maximumCount: maximumCount)
        if commands.contains(where: Self.isContinuous) {
            nextContinuousFlush = now.advanced(by: interval)
        }
        return commands
    }

    public mutating func reset() {
        scheduler.reset()
        nextContinuousFlush = nil
    }

    private static func isContinuous(_ command: RemoteCommand) -> Bool {
        InputCommandScheduler.isBestEffortPointerDelta(command) || command.name == .systemVolumeSet
    }
}
