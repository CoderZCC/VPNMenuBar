import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore
    var onFinished: () -> Void

    @State private var step: Int = 1
    @State private var dependencyStatuses: [DependencyStatus] = []
    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")

    // Dispatcher state for in-app dependency fixes
    @State private var runningFixID: DependencyID? = nil
    @State private var progressLine: String = ""
    @State private var fixError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step) of 4")
                .font(.caption)
                .foregroundColor(.secondary)

            Group {
                switch step {
                case 1: welcomeStep
                case 2: dependencyStep
                case 3: credentialsStep
                default: doneStep
                }
            }

            Spacer()

            HStack {
                if step > 1 && step < 4 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                nextButton
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .onAppear {
            if let existing = (try? configStore.load()) ?? nil {
                config = existing
            }
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

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to VPN MenuBar").font(.title2).bold()
            Text("This app connects to your corporate VPN using openconnect and a TOTP code. Before you start, it needs three things:")
            VStack(alignment: .leading, spacing: 6) {
                Label("openconnect installed via Homebrew", systemImage: "checkmark.shield")
                Label("A sudo NOPASSWD rule for openconnect", systemImage: "checkmark.shield")
                Label("Your username, password prefix, and TOTP secret", systemImage: "checkmark.shield")
            }
            .font(.callout)
            Text("Your config is stored locally at ~/Library/Application Support/com.example.vpnmenubar/config.json with 0600 permissions. Nothing is uploaded.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dependencyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dependency Check").font(.title2).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(dependencyStatuses, id: \.id.rawValue) { status in
                        DependencyRowView(
                            status: status,
                            running: runningFixID == status.id,
                            progressLine: runningFixID == status.id ? progressLine : "",
                            onFix: { fix in
                                Task { await dispatchFix(fix, for: status.id) }
                            }
                        )
                    }
                }
            }
            Button("Recheck") {
                dependencyStatuses = controller.checkDependencies()
            }
            .disabled(runningFixID != nil)
        }
        .onAppear {
            dependencyStatuses = controller.checkDependencies()
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials").font(.title2).bold()
            TextField("Gateway (e.g. vpn.company.com)", text: $config.gateway)
            TextField("Server cert pin (pin-sha256:...)", text: $config.serverCertPin)
            TextField("Username", text: $config.username)
            RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
            RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
            HStack {
                ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
                Spacer()
            }
            Text("All fields above are required. Paths can be edited later in Settings → Advanced.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Set").font(.title2).bold()
            Text("Setup complete. Click the shield icon in the menu bar and choose Connect when you're ready.")
            Text("Heads up: the first time you launch this unsigned app, macOS will show \"cannot be opened\". Go to System Settings → Privacy & Security → Open Anyway to allow it.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Next button

    @ViewBuilder
    private var nextButton: some View {
        switch step {
        case 1:
            Button("Next") { step = 2 }
                .keyboardShortcut(.defaultAction)
        case 2:
            let allPassed = dependencyStatuses.allSatisfy { $0.passed }
            Button("Next") { step = 3 }
                .keyboardShortcut(.defaultAction)
                .disabled(!allPassed || dependencyStatuses.isEmpty)
        case 3:
            Button("Save & Continue") { saveAndAdvance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!config.isConfigured)
        default:
            Button("Done") {
                onFinished()
                Task { await controller.connect() }
            }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func saveAndAdvance() {
        do {
            try configStore.save(config)
            step = 4
        } catch {
            AppLogger.shared.error("OnboardingView save failed: \(error)")
        }
    }

    // MARK: - Fix dispatcher

    @MainActor
    private func dispatchFix(_ fix: InAppFix, for id: DependencyID) async {
        guard runningFixID == nil else { return }
        runningFixID = id
        progressLine = ""
        defer {
            runningFixID = nil
            progressLine = ""
            dependencyStatuses = controller.checkDependencies()
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
            // silent — user cancelled the auth dialog
        } catch let err as DependencyInstallError {
            fixError = err.errorDescription
        } catch {
            fixError = error.localizedDescription
        }
    }
}
