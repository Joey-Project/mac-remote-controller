#if os(macOS)
    import AppleCore
    import CoreGraphics
    import Foundation
    @testable import MacSupport
    import XCTest

    @MainActor
    final class SystemGestureControllerTests: XCTestCase {
        func testOverviewActionsNotifyDockWithoutCreatingOrPostingEvents() throws {
            var notifications: [String] = []
            let controller = SystemGestureController(
                notifyDock: {
                    notifications.append($0); return true
                },
                makeSwipe: { _ in
                    XCTFail("Overview must not create input events"); return nil
                },
                post: { _ in XCTFail("Overview must not post input events") })
            try controller.perform(.missionControl)
            try controller.perform(.appExpose)
            XCTAssertEqual(
                notifications, ["com.apple.expose.awake", "com.apple.expose.front.awake"])
        }

        func testUnavailableOverviewDoesNotFallBackToKeyboard() {
            let controller = SystemGestureController(
                notifyDock: nil, makeSwipe: { _ in nil },
                post: { _ in XCTFail("Unavailable native action must not post events") })
            XCTAssertThrowsError(try controller.perform(.missionControl)) {
                XCTAssertEqual($0 as? SystemGestureError, .unavailable)
            }
        }

        func testRejectedOverviewReportsFailure() {
            let controller = SystemGestureController(
                notifyDock: { _ in false }, makeSwipe: { _ in nil }, post: { _ in })
            XCTAssertThrowsError(try controller.perform(.appExpose)) {
                XCTAssertEqual($0 as? SystemGestureError, .rejected)
            }
        }

        func testSpaceActionsPostOnlyBalancedModifierFreeGestureEvents() throws {
            var posted: [CGEvent] = []
            let controller = SystemGestureController(
                notifyDock: { _ in
                    XCTFail("Spaces must use gesture events"); return false
                },
                makeSwipe: { DockSwipeEvents.make(direction: $0, modern: false) },
                post: { posted.append($0) })
            for action: SystemShortcut in [.previousSpace, .nextSpace] {
                posted.removeAll()
                try controller.perform(action)
                XCTAssertEqual(posted.map(\.type.rawValue), [30, 29, 30, 29, 30, 29])
                XCTAssertTrue(posted.allSatisfy { $0.flags.isEmpty })
                let docks = posted.filter { $0.type.rawValue == 30 }
                let phaseField = try XCTUnwrap(CGEventField(rawValue: 132))
                let progressField = try XCTUnwrap(CGEventField(rawValue: 124))
                XCTAssertEqual(docks.map { $0.getIntegerValueField(phaseField) }, [1, 2, 4])
                XCTAssertEqual(
                    docks.last?.getDoubleValueField(progressField), action == .nextSpace ? 1 : -1)
            }
        }

        func testLateAllocationFailurePostsNoPartialGesture() {
            for failureIndex in 0..<6 {
                var attempts = 0
                let controller = SystemGestureController(
                    notifyDock: nil,
                    makeSwipe: { direction in
                        DockSwipeEvents.make(
                            direction: direction, modern: false,
                            create: {
                                defer { attempts += 1 }
                                return attempts == failureIndex ? nil : CGEvent(source: nil)
                            })
                    }, post: { _ in XCTFail("Allocation failure must not start a gesture") })
                XCTAssertThrowsError(try controller.perform(.nextSpace))
            }
        }

        func testModernPayloadFailurePostsNoPartialGesture() {
            var attached: [UInt32] = []
            let controller = SystemGestureController(
                notifyDock: nil,
                makeSwipe: { direction in
                    DockSwipeEvents.make(
                        direction: direction, modern: true,
                        attachHID: { _, frame in
                            attached.append(frame.phase)
                            return frame.phase != 4
                        })
                }, post: { _ in XCTFail("Missing end payload must not start a gesture") })
            XCTAssertThrowsError(try controller.perform(.previousSpace))
            XCTAssertEqual(attached, [1, 2, 4])
            XCTAssertNil(DockSwipeEvents.make(direction: .next, modern: true))
        }

        func testModernSequenceUsesPayloadForEveryPhaseWithoutLegacyMarkers() throws {
            var frames: [DockSwipeFrame] = []
            let events = try XCTUnwrap(
                DockSwipeEvents.make(
                    direction: .previous, modern: true,
                    attachHID: { _, frame in
                        frames.append(frame); return true
                    }))
            XCTAssertEqual(events.map(\.type.rawValue), [30, 30, 30])
            XCTAssertTrue(events.allSatisfy { $0.flags.isEmpty })
            XCTAssertEqual(frames.map(\.phase), [1, 2, 4])
            XCTAssertEqual(frames.map(\.progress), [0, -0.5, -1])
            XCTAssertEqual(frames.last?.velocity, -400)
        }

        func testSystemHIDPayloadCanBeCreatedAndReadWithoutPosting() throws {
            guard let bridge = NativeHIDEventBridge() else {
                throw XCTSkip("This macOS does not expose the optional HID gesture bridge")
            }
            let library = try XCTUnwrap(
                SystemGestureLibrary(
                    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"))
            typealias CopyHID = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
            typealias GetFlags = @convention(c) (CFTypeRef) -> UInt32
            typealias GetInteger = @convention(c) (CFTypeRef, UInt32) -> CFIndex
            typealias GetDouble = @convention(c) (CFTypeRef, UInt32) -> Double
            let copyHID = try XCTUnwrap(library.symbol("CGEventCopyIOHIDEvent", as: CopyHID.self))
            let getFlags = try XCTUnwrap(
                library.symbol("IOHIDEventGetEventFlags", as: GetFlags.self))
            let getInteger = try XCTUnwrap(
                library.symbol("IOHIDEventGetIntegerValue", as: GetInteger.self))
            let getDouble = try XCTUnwrap(
                library.symbol("IOHIDEventGetDoubleValue", as: GetDouble.self))
            let events = try XCTUnwrap(
                DockSwipeEvents.make(
                    direction: .next, modern: true,
                    attachHID: { bridge.attach(to: $0, frame: $1) }))
            for (index, event) in events.enumerated() {
                let hid = try XCTUnwrap(copyHID(event)?.takeRetainedValue())
                XCTAssertEqual(getFlags(hid) >> 24, [1, 2, 4][index])
                XCTAssertEqual(getInteger(hid, (23 << 16) | 1), 1)
                XCTAssertEqual(getInteger(hid, (23 << 16) | 5), 3)
                XCTAssertEqual(getDouble(hid, (23 << 16) | 2), [0, 0.5, 1][index])
            }
        }
    }
#endif
