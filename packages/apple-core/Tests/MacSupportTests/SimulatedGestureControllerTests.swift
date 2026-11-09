#if os(macOS)
    import AppKit
    import AppleCore
    import CoreGraphics
    @testable import MacSupport
    import XCTest

    @MainActor
    final class SimulatedGestureControllerTests: XCTestCase {
        private let id = UUID()

        private func frame(
            _ phase: RemoteGesturePhase, _ value: Double, time: Double = 10,
            kind: RemoteGestureKind = .magnify
        ) -> RemoteGestureFrame {
            RemoteGestureFrame(id: id, kind: kind, phase: phase, value: value, timestamp: time)
        }

        func testAppKitDecodesMagnificationWithNativePhasesAndLocation() throws {
            let phases: [(RemoteGesturePhase, NSEvent.Phase)] = [
                (.began, .began), (.changed, .changed), (.ended, .ended), (.cancelled, .cancelled)
            ]
            for (phase, expected) in phases {
                let event = try XCTUnwrap(
                    MagnificationEvents.make(
                        delta: 0.125, phase: phase, location: CGPoint(x: 25, y: 40)))
                let native = try XCTUnwrap(NSEvent(cgEvent: event))
                XCTAssertEqual(native.type, .magnify)
                XCTAssertEqual(native.phase, expected)
                XCTAssertEqual(native.magnification, 0.125, accuracy: 0.000001)
                XCTAssertEqual(event.location, CGPoint(x: 25, y: 40))
                XCTAssertTrue(event.flags.isEmpty)
            }
        }

        func testCoalescedPinchPreservesScaleAndAnchorAndEndsWithZeroDelta() throws {
            var posted: [CGEvent] = []
            let controller = SimulatedGestureController(
                make: { kind, phase, value, _, location in
                    XCTAssertEqual(kind, .magnify)
                    return MagnificationEvents.make(delta: value, phase: phase, location: location)
                        .map { [$0] }
                }, post: { posted.append($0) })
            var state = SimulatedGestureState()
            let anchor = CGPoint(x: 20, y: 30)
            try controller.perform(frame(.began, 0), location: anchor, state: &state)
            try controller.perform(
                frame(.changed, log(1.2), time: 10.1), location: .zero, state: &state)
            try controller.perform(
                frame(.ended, log(1.5), time: 10.2), location: .zero, state: &state)
            let native = try posted.map { try XCTUnwrap(NSEvent(cgEvent: $0)) }
            XCTAssertEqual(native.map(\.phase), [.began, .changed, .changed, .ended])
            let scale = native.reduce(1.0) { $0 * (1 + Double($1.magnification)) }
            XCTAssertEqual(scale, 1.5, accuracy: 0.000001)
            XCTAssertEqual(native.last?.magnification, 0)
            XCTAssertTrue(posted.allSatisfy { $0.location == anchor && $0.flags.isEmpty })
            XCTAssertFalse(state.isActive)
        }

        func testCancelUsesPreparedEventsAfterAllocatorFailureAndIsIdempotent() throws {
            var fail = false
            var posted: [CGEvent] = []
            let controller = SimulatedGestureController(
                make: { _, phase, value, _, location in
                    guard !fail else { return nil }
                    return MagnificationEvents.make(delta: value, phase: phase, location: location)
                        .map { [$0] }
                }, post: { posted.append($0) })
            var state = SimulatedGestureState()
            try controller.perform(frame(.began, 0), location: .zero, state: &state)
            fail = true
            XCTAssertThrowsError(
                try controller.perform(frame(.changed, 0.2), location: .zero, state: &state))
            XCTAssertEqual(posted.count, 1)
            XCTAssertTrue(state.isActive)
            controller.cancel(&state)
            controller.cancel(&state)
            XCTAssertEqual(posted.count, 2)
            XCTAssertEqual(
                try XCTUnwrap(NSEvent(cgEvent: XCTUnwrap(posted.last))).phase, .cancelled)
            XCTAssertFalse(state.isActive)
        }

        func testFailedBeginPostsNothingAndRejectsUpdatesWithoutBegin() {
            var state = SimulatedGestureState()
            let controller = SimulatedGestureController(
                make: { _, _, _, _, _ in nil }, post: { _ in XCTFail("No partial begin") })
            XCTAssertThrowsError(
                try controller.perform(frame(.began, 0), location: .zero, state: &state))
            XCTAssertFalse(state.isActive)
            XCTAssertThrowsError(
                try controller.perform(frame(.changed, 0.2), location: .zero, state: &state))
        }

        func testMismatchedIdentityOrBackwardsTimeCannotModifyActiveGesture() throws {
            var posted = 0
            let controller = SimulatedGestureController(
                make: { _, phase, value, _, location in
                    MagnificationEvents.make(delta: value, phase: phase, location: location).map {
                        [$0]
                    }
                }, post: { _ in posted += 1 })
            var state = SimulatedGestureState()
            try controller.perform(frame(.began, 0), location: .zero, state: &state)
            let foreign = RemoteGestureFrame(
                id: UUID(), kind: .magnify, phase: .ended, value: 0, timestamp: 11)
            XCTAssertThrowsError(try controller.perform(foreign, location: .zero, state: &state))
            XCTAssertThrowsError(
                try controller.perform(
                    frame(.changed, 0.2, time: 9), location: .zero, state: &state))
            XCTAssertEqual(posted, 1)
            XCTAssertTrue(state.isActive)
            controller.cancel(&state)
        }

        func testDockFieldsCarryFloatEncodedProgressAxisAndBalancedCancellation() throws {
            for motion: UInt32 in [1, 2] {
                let events = try XCTUnwrap(
                    DockSwipeEvents.makeFrame(
                        DockSwipeFrame(phase: 8, progress: -0.25, velocity: 0, motion: motion),
                        modern: false))
                XCTAssertEqual(events.map(\.type.rawValue), [30, 29])
                let event = try XCTUnwrap(events.first)
                XCTAssertEqual(
                    event.getIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 123))),
                    Int64(motion))
                XCTAssertEqual(
                    event.getIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 135))),
                    Int64(Float(-0.25).bitPattern))
                XCTAssertEqual(
                    event.getDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 119))),
                    Double(Float(bitPattern: motion)))
            }
        }

        func testShortSwipeCancelsAndCompletedSwipeEnds() throws {
            for value in [0.1, 0.8] {
                var posted: [CGEvent] = []
                let controller = SimulatedGestureController(
                    make: { kind, phase, progress, velocity, location in
                        XCTAssertEqual(kind, .verticalSwipe)
                        return DockSwipeEvents.makeFrame(
                            DockSwipeFrame(
                                phase: phase.hidPhase, progress: progress, velocity: velocity,
                                motion: 2), modern: false, location: location)
                    }, post: { posted.append($0) })
                var state = SimulatedGestureState()
                try controller.perform(
                    frame(.began, 0, kind: .verticalSwipe), location: .zero, state: &state)
                try controller.perform(
                    frame(.changed, value, time: 10.1, kind: .verticalSwipe), location: .zero,
                    state: &state)
                try controller.perform(
                    frame(.ended, value, time: 10.2, kind: .verticalSwipe), location: .zero,
                    state: &state)
                let terminal = try XCTUnwrap(posted.dropLast().last)
                XCTAssertEqual(
                    terminal.getIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 132))),
                    value < 0.2 ? 8 : 4)
                XCTAssertFalse(state.isActive)
            }
        }
    }
#endif
