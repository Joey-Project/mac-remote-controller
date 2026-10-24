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
                guard let dock = create(), let type = CGEventType(rawValue: 30) else { return nil }
                dock.type = type
                dock.flags = []
                if modern {
                    guard attachHID?(dock, frame) == true else { return nil }
                } else {
                    configureLegacy(dock, frame: frame, direction: direction)
                }
                events.append(dock)
                if !modern {
                    guard let marker = create(), let type = CGEventType(rawValue: 29) else {
                        return nil
                    }
                    marker.type = type
                    marker.flags = []
                    events.append(marker)
                }
            }
            return events
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
            _ event: CGEvent, frame: DockSwipeFrame, direction: DockSwipeDirection
        ) {
            let integers: [(UInt32, Int64)] = [
                (110, 23),  // IOHIDEventTypeDockSwipe
                (123, 1),  // Horizontal motion
                (132, Int64(frame.phase)),
                (135, direction == .next ? 1 : 0)
            ]
            let doubles: [(UInt32, Double)] = [
                (119, 0), (124, frame.progress), (129, frame.velocity), (130, 0),
                (139, Double(Float.leastNonzeroMagnitude))
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
