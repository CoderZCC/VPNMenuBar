import SwiftUI

struct RevealableSecureField: View {
    let title: String
    @Binding var text: String

    @State private var isVisible: Bool = false

    var body: some View {
        HStack {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
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
