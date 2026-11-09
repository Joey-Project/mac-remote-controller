#if os(macOS)
    import CoreGraphics
    import Foundation

    enum DockSwipeDirection {
        case previous
        case next

        var sign: Double { self == .next ? 1 : -1 }
    }

    struct DockSwipeFrame {
        let phase: UInt32
        let progress: Double
        let velocity: Double
        let motion: UInt32

        init(phase: UInt32, progress: Double, velocity: Double, motion: UInt32 = 1) {
            self.phase = phase
            self.progress = progress
            self.velocity = velocity
            self.motion = motion
        }
    }

    enum DockSwipeEvents {
        /// Dock consumes type 30; older systems also require a type 29 gesture marker.
        /// These undocumented fields are isolated here, never exposed on the wire.
        static func make(
            direction: DockSwipeDirection, modern: Bool,
            create: () -> CGEvent? = { CGEvent(source: nil) },
            attachHID: ((CGEvent, DockSwipeFrame) -> Bool)? = nil
        ) -> [CGEvent]? {
            if modern && attachHID == nil { return nil }
            var events: [CGEvent] = []
            for frame in frames(direction: direction) {
                guard
                    let next = makeFrame(
                        frame, modern: modern, create: create, attachHID: attachHID)
                else { return nil }
                events += next
            }
            return events
        }

        static func makeFrame(
            _ frame: DockSwipeFrame, modern: Bool, location: CGPoint = .zero,
            create: () -> CGEvent? = { CGEvent(source: nil) },
            attachHID: ((CGEvent, DockSwipeFrame) -> Bool)? = nil
        ) -> [CGEvent]? {
            guard let dock = create(), let type = CGEventType(rawValue: 30) else { return nil }
            dock.type = type
            dock.flags = []
            dock.location = location
            if modern {
                guard attachHID?(dock, frame) == true else { return nil }
                return [dock]
            }
            configureLegacy(dock, frame: frame)
            guard let marker = create(), let markerType = CGEventType(rawValue: 29),
                let sourceField = CGEventField(rawValue: 41)
            else { return nil }
            marker.type = markerType
            marker.flags = []
            marker.location = location
            marker.setDoubleValueField(sourceField, value: 33231)
            return [dock, marker]
        }

        private static func frames(direction: DockSwipeDirection) -> [DockSwipeFrame] {
            [
                DockSwipeFrame(phase: 1, progress: 0, velocity: 0),
                DockSwipeFrame(
                    phase: 2, progress: direction.sign * 0.5, velocity: direction.sign * 400),
                DockSwipeFrame(phase: 4, progress: direction.sign, velocity: direction.sign * 400)
            ]
        }

        private static func configureLegacy(
            _ event: CGEvent, frame: DockSwipeFrame
        ) {
            let integers: [(UInt32, Int64)] = [
                (110, 23),  // IOHIDEventTypeDockSwipe
                (123, Int64(frame.motion)),
                (165, Int64(frame.motion)),
                (132, Int64(frame.phase)),
                (134, Int64(frame.phase)),
                (135, Int64(Float(frame.progress).bitPattern)),
                (136, 0)
            ]
            let doubles: [(UInt32, Double)] = [
                (41, 33231), (119, Double(Float(bitPattern: frame.motion))),
                (139, Double(Float(bitPattern: frame.motion))), (124, frame.progress),
                (129, frame.velocity), (130, frame.velocity)
            ]
            for (rawField, value) in integers {
                if let field = CGEventField(rawValue: rawField) {
                    event.setIntegerValueField(field, value: value)
                }
            }
            for (rawField, value) in doubles {
                if let field = CGEventField(rawValue: rawField) {
                    event.setDoubleValueField(field, value: value)
                }
            }
        }
    }
#endif
