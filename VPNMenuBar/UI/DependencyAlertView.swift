import SwiftUI

struct DependencyAlertView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore
    var onClose: () -> Void

    @State private var statuses: [DependencyStatus] = []
    @State private var runningFixID: DependencyID? = nil
    @State private var progressLine: String = ""
    @State private var fixError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                Text("Dependencies").font(.title2).bold()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(statuses, id: \.id.rawValue) { s in
                        DependencyRowView(
                            status: s,
                            running: runningFixID == s.id,
                            progressLine: runningFixID == s.id ? progressLine : "",
                            onFix: { fix in
                                Task { await dispatchFix(fix, for: s.id) }
                            }
                        )
                    }
                }
            }

            Divider()

            HStack {
                Button("Recheck") {
                    statuses = controller.checkDependencies()
                }
                .disabled(runningFixID != nil)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear {
            statuses = controller.checkDependencies()
        }
        .alert("Fix failed", isPresented: Binding(
            get: { fixError != nil },
            set: { if !$0 { fixError = nil } }
        )) {
            Button("OK", role: .cancel) { fixError = nil }
        } message: {
            Text(fixError ?? "")
        }
    }

    // MARK: - Fix dispatcher (mirrors OnboardingView)

    @MainActor
    private func dispatchFix(_ fix: InAppFix, for id: DependencyID) async {
        guard runningFixID == nil else { return }
        runningFixID = id
        progressLine = ""
        defer {
            runningFixID = nil
            progressLine = ""
            statuses = controller.checkDependencies()
        }
        do {
            switch fix {
            case .openTerminalForHomebrew:
                try DependencyInstaller.openTerminalForHomebrew()
            case .installOpenconnect(let brewPath):
                try await DependencyInstaller.installOpenconnect(brewPath: brewPath) { line in
                    Task { @MainActor in
                        self.progressLine = line
                    }
                }
            case .configureSudoers(let user, let path):
                try await DependencyInstaller.installSudoersRule(
                    username: user,
                    openconnectPath: path
                )
            case .resetVpncScriptPath(let newPath):
                try DependencyInstaller.resetVpncScriptPath(to: newPath, store: configStore)
            }
        } catch DependencyInstallError.userCancelled {
            // silent
        } catch let err as DependencyInstallError {
            fixError = err.errorDescription
        } catch {
            fixError = error.localizedDescription
        }
    }
}
