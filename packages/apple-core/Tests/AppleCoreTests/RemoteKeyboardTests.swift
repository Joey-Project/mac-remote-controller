import Foundation
import XCTest
@testable import AppleCore

final class RemoteKeyboardTests: XCTestCase {
    func testNavigationAndShortcutsRoundTripWithoutModifierOrClipboardState() throws {
        let commands =
            RemoteKey.allCases.map { RemoteCommand(name: .keyboardKey, key: $0) }
            + RemoteKeyboardShortcut.allCases.map {
                RemoteCommand(name: .keyboardShortcut, keyboardShortcut: $0)
            }
        for command in commands {
            let message = WireMessage(
                type: .command, connectionID: "keyboard-fixture", requestID: UUID().uuidString,
                sequence: 1, command: command)
            let encoded = try WireCodec.encode(message)
            XCTAssertEqual(try WireCodec.decode(encoded).command, command)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let payload = try XCTUnwrap(object["command"] as? [String: Any])
            XCTAssertEqual(
                Set(payload.keys),
                command.name == .keyboardKey
                    ? ["name", "key"] : ["name", "keyboardShortcut"])
        }
    }

    func testOnlyNewControlsRequireTheAdditiveCapability() throws {
        for key in [RemoteKey.returnKey, .escape, .backspace, .space, .left, .right, .up, .down] {
            XCTAssertFalse(RemoteCommand(name: .keyboardKey, key: key).requiresKeyboardControls)
        }
        for key in [RemoteKey.tab, .forwardDelete, .home, .end, .pageUp, .pageDown] {
            XCTAssertTrue(RemoteCommand(name: .keyboardKey, key: key).requiresKeyboardControls)
        }
        for shortcut in RemoteKeyboardShortcut.allCases {
            XCTAssertTrue(
                RemoteCommand(name: .keyboardShortcut, keyboardShortcut: shortcut)
                    .requiresKeyboardControls)
        }
        let legacy = try JSONDecoder().decode(
            RemoteState.self,
            from: Data(#"{"accessibilityGranted":true,"deviceName":"Mac"}"#.utf8))
        XCTAssertNil(legacy.capabilities)
        XCTAssertFalse(RemoteCommand(name: .keyboardText, text: "draft").requiresKeyboardControls)
    }

    func testRejectsUnknownActionsAndAnyExtraKeyFieldsIncludingNull() throws {
        for json in [
            #"{"name":"keyboard.key","key":"command"}"#,
            #"{"name":"keyboard.key","key":"tab","modifiers":["command"]}"#,
            #"{"name":"keyboard.key","key":"tab","text":null}"#,
            #"{"name":"keyboard.shortcut","keyboardShortcut":"command-down"}"#,
            #"{"name":"keyboard.shortcut","keyboardShortcut":"copy","keyCode":8}"#,
            #"{"name":"keyboard.shortcut","keyboardShortcut":"copy","text":null}"#,
            #"{"name":"keyboard.shortcut","keyboardShortcut":"copy","key":"tab"}"#
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(RemoteCommand.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try RemoteCommand(name: .keyboardShortcut).validate())
        XCTAssertThrowsError(
            try RemoteCommand(name: .keyboardShortcut, text: "clipboard", keyboardShortcut: .paste)
                .validate())
        XCTAssertThrowsError(
            try RemoteCommand(name: .keyboardText, text: "draft", keyboardShortcut: .copy)
                .validate())
    }

    func testShortcutPreservesPriorPointerOrderWithoutAddingHeldInput() {
        var scheduler = InputCommandDispatcher()
        let now = ContinuousClock.now
        let move = RemoteCommand(name: .pointerMove, x: 2, y: 3)
        let shortcut = RemoteCommand(name: .keyboardShortcut, keyboardShortcut: .copy)
        XCTAssertTrue(scheduler.enqueue(move))
        XCTAssertTrue(scheduler.enqueue(shortcut))
        XCTAssertEqual(scheduler.flushDelay(at: now, maximumCount: 2), .zero)
        XCTAssertEqual(scheduler.dequeue(maximumCount: 2, at: now), [move, shortcut])
        XCTAssertTrue(scheduler.dequeue(maximumCount: 2, at: now).isEmpty)
        var held = HeldInputState()
        XCTAssertTrue(held.apply(shortcut).isEmpty)
        XCTAssertTrue(held.buttons.isEmpty)
    }
}
