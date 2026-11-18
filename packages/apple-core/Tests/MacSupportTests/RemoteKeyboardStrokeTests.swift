import AppleCore
import CoreGraphics
import XCTest
@testable import MacSupport

final class RemoteKeyboardStrokeTests: XCTestCase {
    func testEveryAllowlistedKeyHasAnUnmodifiedCompleteNativePair() {
        var codes: Set<Int64> = []
        for key in RemoteKey.allCases {
            var events: [CGEvent] = []
            XCTAssertTrue(RemoteKeyboardStroke(key: key).emit { events.append($0) })
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertTrue(events.allSatisfy { $0.flags.isEmpty })
            if let code = events.first?.getIntegerValueField(.keyboardEventKeycode) {
                codes.insert(code)
                XCTAssertEqual(events.last?.getIntegerValueField(.keyboardEventKeycode), code)
            }
        }
        XCTAssertEqual(codes.count, RemoteKey.allCases.count)
    }

    func testCopyPreparesACompletePairWithoutPostingModifierKeyEvents() throws {
        var events: [CGEvent] = []
        XCTAssertTrue(RemoteKeyboardStroke(shortcut: .copy).emit { events.append($0) })
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [8, 8])
        XCTAssertEqual(events.first?.flags, .maskCommand)
        XCTAssertEqual(events.last?.flags, [])
    }

    func testEveryShortcutClearsItsFlagsAndFollowingPlainKeyIsUnmodified() throws {
        for shortcut in RemoteKeyboardShortcut.allCases {
            var events: [CGEvent] = []
            XCTAssertTrue(RemoteKeyboardStroke(shortcut: shortcut).emit { events.append($0) })
            XCTAssertTrue(RemoteKeyboardStroke(key: .tab).emit { events.append($0) })
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp])
            XCTAssertEqual(events.count, 4)
            XCTAssertNotEqual(events.first?.flags, [])
            XCTAssertTrue(events.dropFirst().allSatisfy { $0.flags.isEmpty })
            XCTAssertTrue(
                events.allSatisfy {
                    ![54, 55, 56, 59, 60, 62].contains(
                        $0.getIntegerValueField(.keyboardEventKeycode))
                }, "Never synthesize Command, Shift or Control key-down events")
        }
    }

    func testRedoAndReverseTabUseOnlyTheirFixedEventFlags() {
        var redo: [CGEvent] = []
        XCTAssertTrue(RemoteKeyboardStroke(shortcut: .redo).emit { redo.append($0) })
        XCTAssertEqual(redo.first?.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(redo.last?.flags, [])
        var previous: [CGEvent] = []
        XCTAssertTrue(RemoteKeyboardStroke(shortcut: .previousField).emit { previous.append($0) })
        XCTAssertEqual(previous.first?.getIntegerValueField(.keyboardEventKeycode), 48)
        XCTAssertEqual(previous.first?.flags, .maskShift)
        XCTAssertEqual(previous.last?.flags, [])
    }
}
