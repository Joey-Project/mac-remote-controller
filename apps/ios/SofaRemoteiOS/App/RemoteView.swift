import AppleCore
import SwiftUI
import UIKit

struct RemoteView: View {
    @Bindable var model: RemoteModel
    @State private var showingScanner = false
    @State private var textToSend = ""
    @State private var volumeValue = 0.5
    @State private var isVolumeEditing = false
    @State private var isTextComposing = false
    @State private var isTextInputFocused = false

    private var remoteEnabled: Bool {
        model.isConnected && model.remoteState?.accessibilityGranted == true
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        ConnectionStatusCard(model: model)

                        if model.isConnected {
                            remoteControls(compact: geometry.size.width < 760)
                        } else {
                            PairingPanel(model: model) {
                                showingScanner = true
                            }
                        }

                        if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(
                                    .red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14)
                                )
                                .accessibilityAddTraits(.isStaticText)
                        }
                    }
                    .frame(maxWidth: 1_000)
                    .padding(.horizontal, geometry.size.width < 600 ? 16 : 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Sofa Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") {
                            model.disconnect()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Disconnect")
                    }
                }
            }
            .sheet(isPresented: $showingScanner) {
                PairingScanner { code in
                    showingScanner = false
                    model.pair(invitation: code)
                }
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
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private func remoteControls(compact: Bool) -> some View {
        VStack(spacing: 18) {
            if !remoteEnabled {
                Label(
                    "Enable Accessibility access on your Mac to control its pointer and keyboard.",
                    systemImage: "hand.raised.fill"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }

            if compact {
                touchpadCard
                keyboardCard
            } else {
                HStack(alignment: .top, spacing: 18) {
                    touchpadCard
                    keyboardCard
                }
            }

            systemVolumeCard
        }
    }

    private var touchpadCard: some View {
        TouchpadCard(
            isEnabled: remoteEnabled,
            onMove: { x, y in model.send(RemoteCommand(name: .pointerMove, x: x, y: y)) },
            onScroll: { x, y in model.send(RemoteCommand(name: .pointerScroll, x: x, y: y)) },
            onTap: { model.send(RemoteCommand(name: .pointerClick, button: .left)) },
            onRightClick: { model.send(RemoteCommand(name: .pointerClick, button: .right)) }
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
                .accessibilityLabel("Send text to Mac")
                .disabled(!canSendText)
            }
            Text(
                isTextComposing
                    ? "Finish composing before sending."
                    : "Text is sent only when you tap Send or press Return."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                keyButton("Return", symbol: "return", key: .returnKey)
                keyButton("Escape", symbol: "escape", key: .escape)
                keyButton("Delete", symbol: "delete.left", key: .backspace)
                keyButton("Space", symbol: "space", key: .space)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18))
    }

    private var systemVolumeCard: some View {
        let systemVolume = model.remoteState?.systemVolume
        let volumeText =
            systemVolume?.formatted(.percent.precision(.fractionLength(0))) ?? "Unavailable"
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                } label: {
                    Label("System volume", systemImage: "arrow.left.arrow.right")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityHint("Player volume will be available with media adapters")
                Spacer()
                Text(volumeText)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(systemVolume == nil ? .secondary : .primary)
                    .accessibilityLabel(systemVolume == nil ? "Volume unavailable" : volumeText)
            }
            Text("Player volume will be available with media adapters")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { isVolumeEditing ? volumeValue : systemVolume ?? volumeValue },
                        set: {
                            volumeValue = $0
                            model.send(RemoteCommand(name: .systemVolumeSet, value: $0))
                        }
                    ), in: 0...1,
                    onEditingChanged: { editing in
                        isVolumeEditing = editing
                        if !editing {
                            model.send(RemoteCommand(name: .systemVolumeSet, value: volumeValue))
                        }
                    }
                )
                .disabled(!model.isConnected || systemVolume == nil)
                .accessibilityLabel("Mac system volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if systemVolume == nil {
                Text(
                    model.remoteState?.systemVolumeReason
                        ?? "System volume control is unavailable on this Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .onAppear(perform: syncSystemVolumeFromRemote)
        .onChange(of: model.remoteState?.systemVolume) { _, _ in
            syncSystemVolumeFromRemote()
        }
    }

    private var canSendText: Bool {
        remoteEnabled && !isTextComposing && !textToSend.isEmpty && textToSend.utf8.count <= 4_096
    }

}

private extension RemoteView {
    func keyButton(_ title: String, symbol: String, key: RemoteKey) -> some View {
        Button {
            model.send(RemoteCommand(name: .keyboardKey, key: key))
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 54)
        }
        .buttonStyle(.bordered)
        .disabled(!remoteEnabled)
    }

    func sendTextFromButton() {
        _ = sendText(textToSend)
    }

    func sendText(_ text: String) -> Bool {
        guard remoteEnabled, !text.isEmpty, text.utf8.count <= 4_096 else { return false }
        guard model.send(RemoteCommand(name: .keyboardText, text: text)) else { return false }
        textToSend = ""
        isTextInputFocused = false
        return true
    }

    func syncSystemVolumeFromRemote() {
        guard !isVolumeEditing, let systemVolume = model.remoteState?.systemVolume else { return }
        volumeValue = systemVolume
    }
}
