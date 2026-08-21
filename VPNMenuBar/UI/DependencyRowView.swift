import SwiftUI
import AppKit

/// Renders a single dependency status row with a Fix button (when an
/// in-app fix is available) and a copyable fallback command.
/// Shared between OnboardingView (step 2) and DependencyAlertView.
struct DependencyRowView: View {
    let status: DependencyStatus

    /// True while a fix action is running for THIS row. The parent owns
    /// the running state and binds it in to disable the button + show a
    /// spinner. The progress line (most recent stdout/stderr line during
    /// `installOpenconnect`) replaces the detail line while running.
    var running: Bool = false
    var progressLine: String = ""

    /// Invoked when the user clicks the Fix button. Parent owns the
    /// dispatch into `DependencyInstaller`.
    var onFix: ((InAppFix) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(status.passed ? .green : .red)
                Text(running && !progressLine.isEmpty ? progressLine : status.detail)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(running ? 1 : nil)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if running {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !status.passed {
                Text(status.fixHint)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .center, spacing: 8) {
                    if let fix = status.inAppFix, let onFix {
                        Button(fixButtonLabel(for: fix)) {
                            onFix(fix)
                        }
                        .disabled(running)
                    }
                    if let cmd = status.fixCommand {
                        Spacer(minLength: 0)
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)
                        Button("Copy") { copy(cmd) }
                    }
                }
            }
        }
    }

    private func fixButtonLabel(for fix: InAppFix) -> String {
        switch fix {
        case .openTerminalForHomebrew:           return "Open Terminal"
        case .installOpenconnect(_, let upgrade):
            return upgrade ? "Upgrade via brew" : "Install via brew"
        case .configureSudoers:                  return "Configure sudo permissions"
        case .resetVpncScriptPath:               return "Reset path"
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
