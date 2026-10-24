import SwiftUI
import UIKit

struct CommittedTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    @Binding var isFocused: Bool
    let placeholder: String
    let onSubmit: (String) -> Bool

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.accessibilityIdentifier = "keyboard.text"
        textField.returnKeyType = .send
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.font = .preferredFont(forTextStyle: .body)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        uiView.delegate = context.coordinator
        uiView.placeholder = placeholder

        if uiView.markedTextRange == nil, uiView.text != text {
            uiView.text = text
        }
        context.coordinator.updateCompositionState(from: uiView)

        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CommittedTextInput

        init(parent: CommittedTextInput) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            updateBindings(from: textField)
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            updateBindings(from: textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
            updateBindings(from: textField)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
            updateBindings(from: textField)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else {
                parent.isComposing = true
                return false
            }

            updateBindings(from: textField)
            guard parent.onSubmit(textField.text ?? "") else { return false }

            textField.text = parent.text
            parent.isFocused = false
            textField.resignFirstResponder()
            return false
        }

        func updateCompositionState(from textField: UITextField) {
            let composing = textField.markedTextRange != nil
            if parent.isComposing != composing {
                parent.isComposing = composing
            }
        }

        private func updateBindings(from textField: UITextField) {
            updateCompositionState(from: textField)
            guard textField.markedTextRange == nil else { return }

            let committedText = textField.text ?? ""
            if parent.text != committedText {
                parent.text = committedText
            }
        }
    }
}
