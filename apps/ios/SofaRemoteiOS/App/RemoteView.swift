import AppleCore
import SwiftUI
import UIKit

enum VolumeScope: Hashable {
    case system
    case player
}

struct RemoteView: View {
    @Bindable var model: RemoteModel
    @State private var showingScanner = false
    @State private var showingConnectionDetails = false
    @State private var showingSettings = false
    @State private var textToSend = ""
    @State var selectedMediaTargetID: String?
    @State var volumeScope: VolumeScope = .system
    @State private var isTextComposing = false
    @State private var isTextInputFocused = false
    @State private var localDragID: UUID?
    @State private var selectedMode: RemoteMode = .touchpad
    @State private var entryRouter = RemoteEntryRouter.shared
    @State private var pendingEntryPoint: RemoteEntryPoint?
    @AppStorage("remote.panels.volume") private var isVolumePinned = false
    @AppStorage("remote.panels.desktop") private var isDesktopPinned = false
    @AppStorage("gesture.threeFingerDrag") private var threeFingerDragEnabled = true
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
                if model.isConnected && !showingSettings {
                    RemoteToolbar(
                        model: model, selectedMode: selectedMode,
                        isVolumePinned: $isVolumePinned,
                        isDesktopPinned: $isDesktopPinned,
                        onSwitchMode: switchMode,
                        onConnectionDetails: {
                            prepareForPresentation()
                            showingConnectionDetails = true
                        },
                        onSettings: openSettings)
                } else if !showingSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: openSettings) {
                            Image(systemName: "gearshape")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("Settings")
                        .accessibilityIdentifier("remote.settings")
                    }
                }
            }
            .navigationDestination(isPresented: $showingSettings) {
                RemoteSettingsView(
                    threeFingerDragEnabled: $threeFingerDragEnabled,
                    forceClickEnabled: $forceClickEnabled, hapticsEnabled: $hapticsEnabled,
                    companionSupportsGestures: model.isConnected ? gesturesSupported : nil)
            }
            .sheet(isPresented: $showingScanner) {
                PairingScanner { code in
                    showingScanner = false
                    model.pair(invitation: code)
                }
            }
            .sheet(isPresented: $showingConnectionDetails) {
                ConnectionDetailsView(
                    model: model,
                    onSwitchTransport: {
                        showingConnectionDetails = false
                        model.selectTransport(
                            model.selectedTransport == .wifi ? .bluetooth : .wifi)
                        resetInteractionState()
                    },
                    onDisconnect: disconnect)
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
                if !connected {
                    showingConnectionDetails = false
                    resetInteractionState()
                }
                if let pendingEntryPoint {
                    selectedMode = pendingEntryPoint == .keyboard ? .keyboard : .touchpad
                    if connected { self.pendingEntryPoint = nil }
                }
            }
            .onChange(of: entryRouter.request, initial: true) { _, request in
                guard let request else { return }
                prepareForPresentation()
                showingSettings = false
                showingConnectionDetails = false
                showingScanner = false
                selectedMode = request.destination == .keyboard ? .keyboard : .touchpad
                pendingEntryPoint = model.isConnected ? nil : request.destination
                entryRouter.request = nil
            }
            .onChange(of: mediaTargetIDs) { _, ids in
                if let selectedMediaTargetID, ids?.contains(selectedMediaTargetID) == true {
                    return
                }
                selectedMediaTargetID = nil
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
                    if model.numericPairing == nil {
                        ConnectionStatusCard(model: model)
                    }
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

            if isVolumePinned || isDesktopPinned {
                controlPanels
                    .padding(.horizontal, horizontalInset(for: availableWidth))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVolumePinned)
        .animation(.easeInOut(duration: 0.2), value: isDesktopPinned)
    }

    private func keyboardMode(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                if isVolumePinned || isDesktopPinned {
                    controlPanels
                        .padding(.horizontal, horizontalInset(for: availableWidth))
                        .padding(.top, 8)
                }
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
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func horizontalInset(for width: CGFloat) -> CGFloat {
        width < 600 ? 12 : 24
    }

    private var controlPanels: some View {
        RemoteControlPanels(
            model: model, volumeScope: $volumeScope, target: selectedMediaTarget,
            showsVolume: isVolumePinned, showsDesktop: isDesktopPinned,
            playback: mediaControlsCard
        ) { action in
            guard remoteEnabled && gesturesSupported else { return }
            prepareForPresentation()
            model.send(RemoteCommand(name: .systemShortcut, shortcut: action))
        }
    }

    private var touchpadCard: some View {
        TouchpadCard(
            isEnabled: remoteEnabled,
            dragEnabled: gesturesSupported && threeFingerDragEnabled,
            shortcutsEnabled: false,
            forceClickEnabled: gesturesSupported && forceClickEnabled,
            hapticsEnabled: gesturesSupported && hapticsEnabled,
            simulatedGesturesEnabled: model.remoteState?.capabilities?.contains(
                WireCapabilities.simulatedGestures) == true,
            rejectedDragID: model.rejectedLocalDragID,
            onMove: { x, y in model.send(RemoteCommand(name: .pointerMove, x: x, y: y)) },
            onScroll: { x, y in model.send(RemoteCommand(name: .pointerScroll, x: x, y: y)) },
            onTap: { timestamp in
                model.send(
                    RemoteCommand(name: .pointerClick, button: .left, tapTimestamp: timestamp))
            },
            onRightClick: { timestamp in
                model.send(
                    RemoteCommand(name: .pointerClick, button: .right, tapTimestamp: timestamp))
            },
            onDragBegin: {
                guard gesturesSupported && threeFingerDragEnabled, localDragID == nil else {
                    return nil
                }
                let dragID = model.beginLocalPointerDrag()
                localDragID = dragID
                return dragID
            },
            onDragMove: { dragID, x, y in
                model.sendLocalPointerDragMove(dragID, x: x, y: y)
            },
            onDragEnd: { releaseLocalDrag() },
            onShortcut: { _ in },
            onGesture: { frame in
                guard
                    model.remoteState?.capabilities?.contains(WireCapabilities.simulatedGestures)
                        == true
                else { return false }
                return model.send(RemoteCommand(name: .gesture, gesture: frame))
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

            RemoteKeyboardControls(isEnabled: remoteEnabled) { key in
                model.send(RemoteCommand(name: .keyboardKey, key: key))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }

    private var canSendText: Bool {
        remoteEnabled && !isTextComposing && !textToSend.isEmpty && textToSend.utf8.count <= 4_096
    }

    private func prepareForPresentation() {
        releaseLocalDrag()
        isTextInputFocused = false
    }

    private func switchMode() {
        prepareForPresentation()
        selectedMode = selectedMode == .touchpad ? .keyboard : .touchpad
    }

    private func openSettings() {
        prepareForPresentation()
        showingSettings = true
    }

    private func disconnect() {
        showingConnectionDetails = false
        releaseLocalDrag()
        model.disconnect()
        resetInteractionState()
    }

    private func resetInteractionState() {
        releaseLocalDrag()
        selectedMode = .touchpad
        volumeScope = .system
        selectedMediaTargetID = nil
        isTextInputFocused = false
        isTextComposing = false
        textToSend = ""
    }
    private func releaseLocalDrag() {
        guard let dragID = localDragID else { return }
        localDragID = nil
        model.endLocalPointerDrag(dragID)
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
