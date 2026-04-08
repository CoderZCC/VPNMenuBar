import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportSecretFromImageButton: View {
    @Binding var secret: String
    @Binding var username: String

    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pickFile) {
                Text("Import from QR image…")
            }
            .disabled(isImporting)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .alert("Import failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
        panel.prompt = "Import"
        panel.message = "Select an image containing a TOTP QR code."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let info = try QRCodeSecretExtractor.extract(fromImageAt: url)
                await MainActor.run {
                    self.secret = info.secret
                    if self.username.isEmpty, let account = info.account {
                        self.username = account
                    }
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isImporting = false
                }
            }
        }
    }
}
