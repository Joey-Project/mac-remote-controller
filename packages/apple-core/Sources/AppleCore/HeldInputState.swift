/// Tracks buttons held by a remote session and expires them if release messages are lost.
public struct HeldInputState: Sendable, Equatable {
    public private(set) var buttons: Set<PointerButton> = []
    public private(set) var lastUpdate: TimeInterval?

    /// Chooses the drag event button, preferring left when both buttons are held.
    public var dragButton: PointerButton? {
        if buttons.contains(.left) { return .left }
        if buttons.contains(.right) { return .right }
        return nil
    }

    public init() {}

    @discardableResult
    public mutating func apply(
        _ command: RemoteCommand, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [PointerButton] {
        switch command.name {
        case .pointerButtonDown:
            if let button = command.button { buttons.insert(button); lastUpdate = uptime }
            return []
        case .pointerButtonUp:
            if let button = command.button { buttons.remove(button) }
            if buttons.isEmpty { lastUpdate = nil } else { lastUpdate = uptime }
            return []
        default:
            return []
        }
    }

    /// Posts releases and removes only buttons whose release callback succeeds.
    @discardableResult
    public mutating func release(
        _ candidates: [PointerButton], posting: (PointerButton) -> Bool
    ) -> [PointerButton] {
        for button in candidates.sorted(by: { $0.rawValue < $1.rawValue })
        where buttons.contains(button) {
            if posting(button) { buttons.remove(button) }
        }
        if buttons.isEmpty { lastUpdate = nil }
        return sortedButtons
    }

    public mutating func refresh(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !buttons.isEmpty { lastUpdate = uptime }
    }

    public func expiredButtons(
        ifOlderThan timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [PointerButton] {
        guard timeout.isFinite, timeout >= 0,
            now.isFinite, let lastUpdate, lastUpdate.isFinite,
            now >= lastUpdate, now - lastUpdate >= timeout
        else { return [] }
        return sortedButtons
    }

    private var sortedButtons: [PointerButton] {
        buttons.sorted { $0.rawValue < $1.rawValue }
    }
}
import Foundation
