#if os(macOS)
    import AppleCore
    import CoreGraphics
    import Foundation

    public struct SimulatedGestureState {
        fileprivate var frame: RemoteGestureFrame?
        fileprivate var location = CGPoint.zero
        fileprivate var cancellation: [CGEvent] = []
        fileprivate var velocity = 0.0
        public private(set) var lastUpdate: TimeInterval?

        public init() {}
        public var isActive: Bool { frame != nil }

        public func expired(at now: TimeInterval, timeout: TimeInterval = 8) -> Bool {
            guard let lastUpdate, now.isFinite, timeout.isFinite, timeout >= 0 else { return false }
            return now >= lastUpdate && now - lastUpdate >= timeout
        }

        fileprivate mutating func refresh() { lastUpdate = ProcessInfo.processInfo.systemUptime }
    }

    /// Owns balanced native event sequences. Cancellation events are prepared
    /// before every emission so disconnect cleanup does not require allocation.
    @MainActor
    public final class SimulatedGestureController {
        typealias MakeEvents =
            (RemoteGestureKind, RemoteGesturePhase, Double, Double, CGPoint) -> [CGEvent]?
        private let make: MakeEvents
        private let post: (CGEvent) -> Void
        public let isAvailable: Bool

        public convenience init() {
            let bridge = NativeHIDEventBridge()
            let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            self.init(
                isAvailable: !modern || bridge != nil,
                make: { kind, phase, value, velocity, location in
                    if kind == .magnify {
                        return MagnificationEvents.make(
                            delta: value, phase: phase, location: location
                        ).map { [$0] }
                    }
                    return DockSwipeEvents.makeFrame(
                        DockSwipeFrame(
                            phase: phase.hidPhase, progress: value, velocity: velocity,
                            motion: kind == .horizontalSwipe ? 1 : 2),
                        modern: modern, location: location,
                        attachHID: bridge.map { bridge in { bridge.attach(to: $0, frame: $1) } })
                }, post: { $0.post(tap: .cgSessionEventTap) })
        }

        init(
            isAvailable: Bool = true, make: @escaping MakeEvents, post: @escaping (CGEvent) -> Void
        ) {
            self.isAvailable = isAvailable
            self.make = make
            self.post = post
        }

        public func perform(
            _ frame: RemoteGestureFrame, location: CGPoint, state: inout SimulatedGestureState
        ) throws {
            try frame.validate()
            guard isAvailable else { throw SystemGestureError.unavailable }
            if frame.phase == .began {
                guard !state.isActive else {
                    throw WireProtocolError.invalidCommand("A gesture is already active")
                }
                let cancel = try events(frame.kind, .cancelled, 0, 0, location)
                let start = try events(frame.kind, .began, 0, 0, location)
                state.frame = frame
                state.location = location
                state.cancellation = cancel
                state.refresh()
                start.forEach(post)
                return
            }
            guard let previous = state.frame else {
                if frame.phase.isTerminal { return }
                throw WireProtocolError.invalidCommand("The gesture has not begun")
            }
            guard frame.id == previous.id, frame.kind == previous.kind,
                frame.timestamp >= previous.timestamp
            else { throw WireProtocolError.invalidCommand("Gesture identity or timestamp changed") }

            if frame.phase == .cancelled { cancel(&state); return }
            let difference = frame.value - previous.value
            let elapsed = frame.timestamp - previous.timestamp
            let velocity =
                difference == 0
                ? (elapsed < 0.12 ? state.velocity : 0)
                : (elapsed > 0 ? min(20, max(-20, difference / elapsed)) : 0)
            let amount = frame.kind == .magnify ? exp(difference) - 1 : frame.value
            let cancelValue = frame.kind == .magnify ? 0 : frame.value
            let cancellation = try events(frame.kind, .cancelled, cancelValue, 0, state.location)
            var outgoing: [CGEvent] = []
            if difference != 0 {
                outgoing = try events(frame.kind, .changed, amount, velocity, state.location)
            }
            if frame.phase == .ended {
                let reverse = velocity * frame.value < 0
                let shouldCancel = frame.kind != .magnify && (abs(frame.value) < 0.2 || reverse)
                outgoing += try events(
                    frame.kind, shouldCancel ? .cancelled : .ended,
                    cancelValue, shouldCancel ? 0 : velocity, state.location)
            }
            // Nothing is posted until this frame's terminal/cancellation path exists.
            state.frame = frame
            state.velocity = velocity
            state.cancellation = cancellation
            state.refresh()
            outgoing.forEach(post)
            if frame.phase.isTerminal { state = SimulatedGestureState() }
        }

        public func cancel(_ state: inout SimulatedGestureState) {
            state.cancellation.forEach(post)
            state = SimulatedGestureState()
        }

        private func events(
            _ kind: RemoteGestureKind, _ phase: RemoteGesturePhase, _ value: Double,
            _ velocity: Double, _ location: CGPoint
        ) throws -> [CGEvent] {
            guard let events = make(kind, phase, value, velocity, location), !events.isEmpty else {
                throw SystemGestureError.unavailable
            }
            return events
        }
    }

    extension RemoteGesturePhase {
        var hidPhase: UInt32 {
            switch self {
            case .began: 1
            case .changed: 2
            case .ended: 4
            case .cancelled: 8
            }
        }
    }

    enum MagnificationEvents {
        /// Private CGEvent gesture fields, also used by Mac Mouse Fix's
        /// TouchSimulator. AppKit must decode this as magnify, not scroll/key input.
        static func make(delta: Double, phase: RemoteGesturePhase, location: CGPoint) -> CGEvent? {
            guard let event = CGEvent(source: nil), let type = CGEventType(rawValue: 29),
                let subtype = CGEventField(rawValue: 110),
                let amount = CGEventField(rawValue: 113),
                let phaseField = CGEventField(rawValue: 132)
            else { return nil }
            event.type = type
            event.flags = []
            event.location = location
            event.setIntegerValueField(subtype, value: 8)
            event.setDoubleValueField(amount, value: delta)
            event.setIntegerValueField(phaseField, value: Int64(phase.hidPhase))
            return event
        }
    }
#endif
