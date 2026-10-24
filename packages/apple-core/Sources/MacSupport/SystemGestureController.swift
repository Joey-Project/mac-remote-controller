#if os(macOS)
    import AppleCore
    import CoreGraphics
    import Foundation

    /// Executes the fixed remote actions without creating keyboard events.
    @MainActor
    public final class SystemGestureController {
        private let notifyDock: ((String) -> Bool)?
        private let makeSwipe: (DockSwipeDirection) -> [CGEvent]?
        private let post: (CGEvent) -> Void

        public convenience init() {
            let dock = NativeDockNotification()
            let hid = NativeHIDEventBridge()
            self.init(
                notifyDock: dock.map { dock in { dock.send($0) } },
                makeSwipe: { direction in
                    if #available(macOS 27, *) {
                        return DockSwipeEvents.make(
                            direction: direction, modern: true,
                            attachHID: hid.map { bridge in { bridge.attach(to: $0, frame: $1) } })
                    }
                    return DockSwipeEvents.make(direction: direction, modern: false)
                },
                post: { $0.post(tap: .cgSessionEventTap) })
        }

        init(
            notifyDock: ((String) -> Bool)?,
            makeSwipe: @escaping (DockSwipeDirection) -> [CGEvent]?,
            post: @escaping (CGEvent) -> Void
        ) {
            self.notifyDock = notifyDock
            self.makeSwipe = makeSwipe
            self.post = post
        }

        public func perform(_ action: SystemShortcut) throws {
            switch action {
            case .missionControl:
                try notify("com.apple.expose.awake")
            case .appExpose:
                try notify("com.apple.expose.front.awake")
            case .previousSpace, .nextSpace:
                let direction: DockSwipeDirection = action == .nextSpace ? .next : .previous
                // Prepare the complete begin/change/end sequence before posting any part.
                guard let events = makeSwipe(direction), !events.isEmpty else {
                    throw SystemGestureError.unavailable
                }
                for event in events { post(event) }
            }
        }

        private func notify(_ name: String) throws {
            guard let notifyDock else { throw SystemGestureError.unavailable }
            guard notifyDock(name) else { throw SystemGestureError.rejected }
        }
    }

    public enum SystemGestureError: Error, LocalizedError {
        case unavailable
        case rejected

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Native Mac gestures are unavailable on this version of macOS."
            case .rejected: "macOS could not perform the requested desktop gesture."
            }
        }
    }
#endif
