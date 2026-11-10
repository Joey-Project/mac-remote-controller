import AppleCore
import SwiftUI

struct NumericPairingInput: View {
    @Bindable var model: RemoteModel
    @Bindable var state: NumericPairingClientState
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pair with \(state.macName)", systemImage: "desktopcomputer")
                .font(.title3.weight(.semibold))
            if state.phase == .connecting {
                ProgressView("Requesting a code on the Mac…")
            } else {
                Text("Enter the four-digit code shown on your Mac.")
                    .foregroundStyle(.secondary)
                TextField("4-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .tracking(6)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(
                        Color(uiColor: .tertiarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .focused($codeFocused)
                    .disabled(state.phase != .input)
                    .accessibilityIdentifier("pairing.code")
                    .privacySensitive()
                    .onChange(of: code) { _, value in
                        code =
                            String(
                                bytes: value.utf8.filter { (48...57).contains($0) }.prefix(4),
                                encoding: .utf8) ?? ""
                    }
                Text(
                    state.remainingAttempts == 1
                        ? "1 attempt remaining" : "\(state.remainingAttempts) attempts remaining"
                )
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("pairing.attempts")
                if let error = state.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .accessibilityIdentifier("pairing.codeError")
                }
                HStack(spacing: 16) {
                    Button("Pair with Mac") {
                        let submitted = code
                        code = ""
                        model.submitNumericCode(submitted)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.phase != .input || !NumericPairingCode.isValid(code))
                    .accessibilityIdentifier("pairing.submit")
                    cancelButton
                }
                if state.phase != .input {
                    ProgressView("Verifying code and Mac identity…")
                        .accessibilityIdentifier("pairing.progress")
                }
            }
            if state.phase == .connecting { cancelButton }
        }
        .onAppear { codeFocused = state.phase == .input }
        .onChange(of: state.phase) { _, phase in codeFocused = phase == .input }
    }

    private var cancelButton: some View {
        Button("Cancel pairing", role: .cancel) {
            codeFocused = false
            model.disconnect()
        }
        .accessibilityIdentifier("pairing.cancel")
    }
}
