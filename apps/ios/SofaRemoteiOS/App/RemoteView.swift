import AppleCore
import SwiftUI
import UIKit

struct RemoteView: View {
    @Bindable var model: RemoteModel
    @State private var showingScanner = false
    @State private var showingBenchmark = false
    @State private var textToSend = ""
    @State private var isTextComposing = false
    @State private var isTextInputFocused = false
    @State private var localDragID: UUID?
    @State private var selectedMode: RemoteMode = .touchpad
    @State private var isVolumePinned = false
    @AppStorage("gesture.threeFingerDrag") private var threeFingerDragEnabled = true
    @AppStorage("gesture.fourFingerShortcuts") private var fourFingerShortcutsEnabled = true
    @AppStorage("gesture.forceClick") private var forceClickEnabled = true
    @AppStorage("gesture.haptics") private var hapticsEnabled = false

    private var gesturesSupported: Bool { model.remoteState?.supportsGestures == true }

    private var remoteEnabled: Bool {
        model.isConnected && model.remoteState?.accessibilityGranted == true
    }

    private var navigationTitle: String {
        model.isConnected ? (model.remoteState?.deviceName ?? "Mac") : "Sofa Remote"
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isConnected {
                    connectedContent
                } else {
                    disconnectedContent
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        RemoteActionsMenu(
                            model: model, selectedMode: $selectedMode,
                            isVolumePinned: $isVolumePinned,
                            gesturesSupported: gesturesSupported,
                            threeFingerDragEnabled: $threeFingerDragEnabled,
                            fourFingerShortcutsEnabled: $fourFingerShortcutsEnabled,
                            forceClickEnabled: $forceClickEnabled,
                            hapticsEnabled: $hapticsEnabled,
                            onTouchpad: {
                                selectedMode = .touchpad
                                isTextInputFocused = false
                            },
                            onKeyboard: {
                                selectedMode = .keyboard
                            },
                            onSwitchTransport: {
                                model.selectTransport(
                                    model.selectedTransport == .wifi ? .bluetooth : .wifi)
                                resetInteractionState()
                            },
                            onBenchmark: { showingBenchmark = true },
                            onDisconnect: disconnect)
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                PairingScanner { code in
                    showingScanner = false
                    model.pair(invitation: code)
                }
            }
            .sheet(isPresented: $showingBenchmark) {
                ConnectionBenchmarkSheet(model: model, isPresented: $showingBenchmark)
            }
            .alert(
                "Connection problem",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "Please try again.")
            }
            .onChange(of: model.isConnected) { _, connected in
                if !connected { resetInteractionState() }
            }
            .onChange(of: model.rejectedLocalDragID) { _, rejectedID in
                if localDragID == rejectedID { localDragID = nil }
            }
        }
        .tint(.accentColor)
    }
}

private extension RemoteView {
    private var connectedContent: some View {
        GeometryReader { geometry in
            if selectedMode == .touchpad {
                touchpadMode(availableWidth: geometry.size.width)
            } else {
                keyboardMode(availableWidth: geometry.size.width)
            }
        }
    }

    private var disconnectedContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionStatusCard(model: model)
                    PairingPanel(model: model) {
                        showingScanner = true
                    }
                }
                .frame(maxWidth: 1_000)
                .padding(.horizontal, geometry.size.width < 600 ? 16 : 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func touchpadMode(availableWidth: CGFloat) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                if !remoteEnabled {
                    Label(
                        "Enable Accessibility access on your Mac to control its pointer "
                            + "and keyboard.",
                        systemImage: "hand.raised.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isStaticText)
                }

                touchpadCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, horizontalInset(for: availableWidth))
            .padding(.top, 8)
            .padding(.bottom, 12)

            if isVolumePinned {
                systemVolumeCard
                    .padding(.horizontal, horizontalInset(for: availableWidth))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVolumePinned)
    }

    private func keyboardMode(availableWidth: CGFloat) -> some View {
        VStack(spacing: 10) {
            systemVolumeCard
                .padding(.horizontal, horizontalInset(for: availableWidth))
                .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    if !remoteEnabled {
                        Label(
                            "Enable Accessibility access on your Mac to use the keyboard.",
                            systemImage: "hand.raised.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    keyboardCard
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        width < 600 ? 12 : 24
    }

    private var touchpadCard: some View {
        TouchpadCard(
            isEnabled: remoteEnabled,
            dragEnabled: gesturesSupported && threeFingerDragEnabled,
            shortcutsEnabled: gesturesSupported && fourFingerShortcutsEnabled,
            forceClickEnabled: gesturesSupported && forceClickEnabled,
            hapticsEnabled: gesturesSupported && hapticsEnabled,
            onMove: { x, y in model.send(RemoteCommand(name: .pointerMove, x: x, y: y)) },
            onScroll: { x, y in model.send(RemoteCommand(name: .pointerScroll, x: x, y: y)) },
            onTap: { model.send(RemoteCommand(name: .pointerClick, button: .left)) },
            onRightClick: { model.send(RemoteCommand(name: .pointerClick, button: .right)) },
            onDragBegin: {
                guard gesturesSupported && threeFingerDragEnabled, localDragID == nil else {
                    return
                }
                localDragID = model.beginLocalPointerDrag()
            },
            onDragEnd: { releaseLocalDrag() },
            onShortcut: { action in
                guard gesturesSupported && fourFingerShortcutsEnabled else { return }
                model.send(RemoteCommand(name: .systemShortcut, shortcut: action))
            }
        )
    }

    private var keyboardCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Keyboard", systemImage: "keyboard")
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                CommittedTextInput(
                    text: $textToSend,
                    isComposing: $isTextComposing,
                    isFocused: $isTextInputFocused,
                    placeholder: "Type a message",
                    onSubmit: sendText
                )
                .frame(minHeight: 44)
                .padding(12)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
                Button {
                    sendTextFromButton()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .accessibilityLabel("Send text to Mac").accessibilityIdentifier("keyboard.send")
                .disabled(!canSendText)
            }
            Text(
                isTextComposing
                    ? "Finish composing before sending."
                    : "Text is sent only when you tap Send or press Return."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            keyboardKeypad
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }

    private var keyboardKeypad: some View {
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

    private var systemVolumeCard: some View { SystemVolumeCard(model: model) }

    private var canSendText: Bool {
        remoteEnabled && !isTextComposing && !textToSend.isEmpty && textToSend.utf8.count <= 4_096
    }

    private func disconnect() {
        releaseLocalDrag()
        model.disconnect()
        resetInteractionState()
    }

    private func resetInteractionState() {
        releaseLocalDrag()
        selectedMode = .touchpad
        isVolumePinned = false
        isTextInputFocused = false
        isTextComposing = false
        textToSend = ""
    }
    private func releaseLocalDrag() {
        guard let dragID = localDragID else { return }
        localDragID = nil
        model.endLocalPointerDrag(dragID)
    }
    func keyButton(_ title: String, symbol: String, key: RemoteKey, compact: Bool = false)
        -> some View
    {
        Button {
            model.send(RemoteCommand(name: .keyboardKey, key: key))
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
        .disabled(!remoteEnabled)
        .accessibilityLabel(compact ? "\(title) arrow key" : "\(title) key")
        .accessibilityIdentifier("key.\(key.rawValue)")
    }
    func sendTextFromButton() { _ = sendText(textToSend) }

    func sendText(_ text: String) -> Bool {
        guard remoteEnabled, !text.isEmpty, text.utf8.count <= 4_096 else { return false }
        guard model.send(RemoteCommand(name: .keyboardText, text: text)) else { return false }
        textToSend = ""
        isTextInputFocused = false
        return true
    }

}
