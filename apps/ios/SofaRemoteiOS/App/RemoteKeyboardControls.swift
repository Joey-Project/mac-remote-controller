import AppleCore
import SwiftUI

struct RemoteKeyboardControls: View {
    let isEnabled: Bool
    let supportsExtendedKeyboard: Bool
    let onKey: (RemoteKey) -> Void
    let onShortcut: (RemoteKeyboardShortcut) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                keyButton("Return", symbol: "return", key: .returnKey)
                keyButton("Escape", symbol: "escape", key: .escape)
                keyButton("Delete", symbol: "delete.left", key: .backspace)
            }
            directionalPad
            if !supportsExtendedKeyboard {
                Text("Update the Mac companion to use navigation and editing shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("keyboard.updateRequired")
            }
            Text("Navigation").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 8) {
                keyButton("Tab", symbol: "arrow.right.to.line", key: .tab)
                shortcutButton("Previous field", keys: "⇧ Tab", shortcut: .previousField)
                keyButton("Forward delete", symbol: "delete.right", key: .forwardDelete)
                keyButton("Home", symbol: "arrow.up.to.line", key: .home)
                keyButton("End", symbol: "arrow.down.to.line", key: .end)
                keyButton("Page Up", symbol: "arrow.up.doc", key: .pageUp)
                keyButton("Page Down", symbol: "arrow.down.doc", key: .pageDown)
            }
            Text("Editing shortcuts").font(.headline).frame(
                maxWidth: .infinity, alignment: .leading)
            Text("Applies to the active app on your Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 8) {
                shortcutButton("Copy", keys: "⌘C", shortcut: .copy)
                shortcutButton("Cut", keys: "⌘X", shortcut: .cut)
                shortcutButton("Paste", keys: "⌘V", shortcut: .paste)
                shortcutButton("Select all", keys: "⌘A", shortcut: .selectAll)
                shortcutButton("Undo", keys: "⌘Z", shortcut: .undo)
                shortcutButton("Redo", keys: "⇧⌘Z", shortcut: .redo)
                shortcutButton("Find", keys: "⌘F", shortcut: .find)
            }
        }
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 44), spacing: 8), count: 3)
    }

    private func shortcutButton(_ title: String, keys: String, shortcut: RemoteKeyboardShortcut)
        -> some View
    {
        Button {
            onShortcut(shortcut)
        } label: {
            VStack(spacing: 6) {
                Text(keys).font(.headline)
                Text(title).font(.caption2)
            }.frame(maxWidth: .infinity).frame(minHeight: 54)
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44)
        .disabled(!isEnabled || !supportsExtendedKeyboard)
        .accessibilityLabel("\(title) on Mac (\(keys))")
        .accessibilityIdentifier("keyboard.shortcut.\(shortcut.rawValue)")
    }

    private var directionalPad: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 6), count: 4),
            spacing: 6
        ) {
            Color.clear.frame(height: 54).accessibilityHidden(true)
            Color.clear.frame(height: 54).accessibilityHidden(true)
            keyButton("Up", symbol: "arrow.up", key: .up, compact: true)
            Color.clear.frame(height: 54).accessibilityHidden(true)
            keyButton("Space", symbol: "space", key: .space)
            keyButton("Left", symbol: "arrow.left", key: .left, compact: true)
            keyButton("Down", symbol: "arrow.down", key: .down, compact: true)
            keyButton("Right", symbol: "arrow.right", key: .right, compact: true)
        }
    }

    private func keyButton(_ title: String, symbol: String, key: RemoteKey, compact: Bool = false)
        -> some View
    {
        Button {
            onKey(key)
        } label: {
            Group {
                if compact {
                    Image(systemName: symbol).font(.headline)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text(title).font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44)
        .disabled(!isEnabled || (key.requiresKeyboardControls && !supportsExtendedKeyboard))
        .accessibilityLabel(compact ? "\(title) arrow key" : "\(title) key")
        .accessibilityIdentifier("key.\(key.rawValue)")
    }
}
