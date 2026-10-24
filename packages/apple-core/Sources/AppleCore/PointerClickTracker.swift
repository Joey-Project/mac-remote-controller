import Foundation

public enum PointerClickTimebase: Sendable, Equatable {
    case client
    case server
}

public struct PointerClickRequest: Sendable, Equatable {
    public var button: PointerButton
    public var x: Double
    public var y: Double
    public var uptime: TimeInterval
    public var doubleClickInterval: TimeInterval
    public var maximumDistance: Double
    public var timebase: PointerClickTimebase

    public init(
        button: PointerButton, x: Double, y: Double, uptime: TimeInterval,
        doubleClickInterval: TimeInterval, maximumDistance: Double = 4,
        timebase: PointerClickTimebase = .server
    ) {
        self.button = button
        self.x = x
        self.y = y
        self.uptime = uptime
        self.doubleClickInterval = doubleClickInterval
        self.maximumDistance = maximumDistance
        self.timebase = timebase
    }
}

/// Assigns native single/double click state to consecutive clicks within one remote session.
public struct PointerClickTracker: Sendable, Equatable {
    private struct PreviousClick: Sendable, Equatable {
        var button: PointerButton
        var x: Double
        var y: Double
        var uptime: TimeInterval
        var timebase: PointerClickTimebase
    }

    private var previous: PreviousClick?

    public init() {}

    public mutating func register(
        button: PointerButton, x: Double, y: Double, at uptime: TimeInterval,
        doubleClickInterval: TimeInterval, maximumDistance: Double = 4,
        timebase: PointerClickTimebase = .server
    ) -> Int {
        guard x.isFinite, y.isFinite, uptime.isFinite, doubleClickInterval.isFinite,
            maximumDistance.isFinite, doubleClickInterval >= 0, maximumDistance >= 0
        else { previous = nil; return 1 }

        if let previous, previous.timebase == timebase, previous.button == button,
            uptime >= previous.uptime, uptime - previous.uptime <= doubleClickInterval,
            hypot(x - previous.x, y - previous.y) <= maximumDistance
        {
            self.previous = nil
            return 2
        }
        previous = PreviousClick(
            button: button, x: x, y: y, uptime: uptime, timebase: timebase)
        return 1
    }

    /// Commits click history only after the supplied event creation/posting succeeds.
    @discardableResult
    public mutating func emitClick(
        _ request: PointerClickRequest,
        posting: (Int) throws -> Void
    ) rethrows -> Int {
        var preview = self
        let clickState = preview.register(
            button: request.button, x: request.x, y: request.y, at: request.uptime,
            doubleClickInterval: request.doubleClickInterval,
            maximumDistance: request.maximumDistance, timebase: request.timebase)
        try posting(clickState)
        _ = register(
            button: request.button, x: request.x, y: request.y, at: request.uptime,
            doubleClickInterval: request.doubleClickInterval,
            maximumDistance: request.maximumDistance, timebase: request.timebase)
        return clickState
    }

    public mutating func reset() { previous = nil }
}
