import AppleCore
import SwiftUI

struct RemoteKeyboardControls: View {
    let isEnabled: Bool
    let onKey: (RemoteKey) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                keyButton("Return", symbol: "return", key: .returnKey)
                keyButton("Escape", symbol: "escape", key: .escape)
                keyButton("Delete", symbol: "delete.left", key: .backspace)
            }
            directionalPad
        }
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
        .disabled(!isEnabled)
        .accessibilityLabel(compact ? "\(title) arrow key" : "\(title) key")
        .accessibilityIdentifier("key.\(key.rawValue)")
    }
}
