import SwiftUI
import AppKit

struct RevealableSecureField: View {
    let title: String
    @Binding var text: String

    @State private var isVisible: Bool = false

    var body: some View {
        // LabeledContent supplies the leading label that Form would otherwise
        // take from TextField(title:) — an NSViewRepresentable can't provide it.
        LabeledContent(title) {
            HStack {
                ASCIIOnlyTextField(text: $text, isSecure: !isVisible)
                    .id(isVisible)    // swap NSTextField <-> NSSecureTextField
                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isVisible ? "Hide" : "Show")
            }
        }
    }
}

/// A credential field that forces the input source to a Roman one while it has
/// focus.
///
/// macOS does not switch input methods for password fields — only the system
/// login window does. With a Chinese IME active a user types `！` (U+FF01)
/// instead of `!`, which is one character like the real thing, renders as the
/// same dot behind the mask, and is silently rejected by the gateway as a bad
/// password. SwiftUI's SecureField exposes no way to set this, hence the
/// AppKit wrapper.
/// The restriction lives on the field editor (an NSTextView), not on the text
/// field itself, and the field editor only exists once the field has focus.
private protocol RomanInputRestricting: NSTextField {}

extension RomanInputRestricting {
    func restrictFieldEditorToRomanInput() {
        (currentEditor() as? NSTextView)?
            .allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
    }
}

private final class RomanOnlyTextField: NSTextField, RomanInputRestricting {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { restrictFieldEditorToRomanInput() }
        return accepted
    }
}

private final class RomanOnlySecureTextField: NSSecureTextField, RomanInputRestricting {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { restrictFieldEditorToRomanInput() }
        return accepted
    }
}

private struct ASCIIOnlyTextField: NSViewRepresentable {
    @Binding var text: String
    let isSecure: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? RomanOnlySecureTextField() : RomanOnlyTextField()
        field.delegate = context.coordinator
        // isBezeled + roundedBezel matches SwiftUI's own TextField in a Form;
        // setting isBordered instead produces a square border that doesn't.
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.stringValue = text
        // Match the sizing behaviour of the SwiftUI TextFields around it;
        // without this the Form gives the field its full intrinsic width.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
