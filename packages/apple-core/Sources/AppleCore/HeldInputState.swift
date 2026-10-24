/// Tracks buttons held by a remote session and expires them if release messages are lost.
public struct HeldInputState: Sendable, Equatable {
    public private(set) var buttons: Set<PointerButton> = []
    public private(set) var lastUpdate: TimeInterval?

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

    public mutating func releaseAll() -> [PointerButton] {
        let held = buttons
        buttons.removeAll()
        lastUpdate = nil
        return held.sorted { $0.rawValue < $1.rawValue }
    }

    public mutating func refresh(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if !buttons.isEmpty { lastUpdate = uptime }
    }

    public mutating func expire(
        ifOlderThan timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [PointerButton] {
        guard let lastUpdate, now - lastUpdate >= timeout else { return [] }
        return releaseAll()
    }
}
import Foundation
