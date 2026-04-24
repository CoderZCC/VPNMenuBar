import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore

    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
    @State private var originalConfig: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabledPreference
    @State private var showSavedAlert: Bool = false
    @State private var savedAlertTitle: String = ""
    @State private var savedAlertMessage: String = ""

    private var hasChanges: Bool { config != originalConfig }

    var body: some View {
        Form {
            Section("Required") {
                TextField("Gateway", text: $config.gateway)
                TextField("Server cert pin", text: $config.serverCertPin)
                TextField("Username", text: $config.username)
                RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
                RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
                HStack {
                    ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
                    Spacer()
                }
            }

            Section("Advanced") {
                TextField("openconnect path", text: $config.openconnectPath)
                TextField("vpnc-script path", text: $config.vpncScriptPath)
                Toggle("Skip DNS modification (use bundled vpnc-script--no-dns)",
                       isOn: $config.skipDNSModification)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LoginItemManager.isEnabledPreference = newValue
                    }
                HStack {
                    Text("Log file")
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(
                            AppLogger.shared.logFileURL.path,
                            inFileViewerRootedAtPath: AppLogger.shared.logDirectory.path
                        )
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                }
            }
        }
        .padding()
        .frame(width: 640)
        .onAppear(perform: load)
        .alert(savedAlertTitle, isPresented: $showSavedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(savedAlertMessage)
        }
    }

    private func load() {
        if let existing = (try? configStore.load()) ?? nil {
            config = existing
            originalConfig = existing
        }
    }

    private func save() {
        do {
            try configStore.save(config)
            // Close settings window and trigger a reconnect
            NSApp.keyWindow?.close()
            Task {
                if controller.state.isConnected {
                    await controller.disconnect()
                }
                await controller.connect()
            }
        } catch {
            AppLogger.shared.error("SettingsView save failed: \(error)")
            savedAlertTitle = "Save Failed"
            savedAlertMessage = "The config file may be read-only — check permissions under ~/Library/Application Support."
            showSavedAlert = true
        }
    }
}
