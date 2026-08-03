import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore

    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
    @State private var originalConfig: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabledPreference
    @State private var autoConnectOnLaunch: Bool = AutoConnectPreference.isEnabled
    @State private var showSavedAlert: Bool = false
    @State private var showNonASCIIWarning: Bool = false
    @State private var nonASCIIWarningMessage: String = ""
    @State private var hasConfirmedNonASCII: Bool = false
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
                Toggle("Server asks for password and OTP separately (two-step)",
                       isOn: Binding(
                           get: { config.otpSentSeparately ?? false },
                           set: { config.otpSentSeparately = $0 }
                       ))
            }

            Section("Advanced") {
                TextField("openconnect path", text: $config.openconnectPath)
                TextField("vpnc-script path", text: $config.vpncScriptPath)
                // Kept as a .help tooltip rather than a caption Text: a wrapping
                // label in this Section made NSHostingController throw while
                // sizing the window (v0.2.10 crashed on opening Settings).
                // The .frame(width: 640) below does not prevent it.
                TextField("User-Agent", text: Binding(
                    get: { config.userAgent ?? VPNConfig.defaultUserAgent },
                    set: { config.userAgent = $0 }
                ))
                .help("Some gateways only serve the OTP form to the official Cisco client and reject openconnect's own User-Agent with a 401. Leave empty to send openconnect's default.")
                Toggle("Skip DNS modification (use bundled vpnc-script--no-dns)",
                       isOn: $config.skipDNSModification)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LoginItemManager.isEnabledPreference = newValue
                    }
                Toggle("Auto-connect on launch", isOn: $autoConnectOnLaunch)
                    .onChange(of: autoConnectOnLaunch) { newValue in
                        AutoConnectPreference.isEnabled = newValue
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
        .alert("Non-ASCII characters in credentials", isPresented: $showNonASCIIWarning) {
            Button("Go Back and Fix", role: .cancel) { }
            Button("Save Anyway") {
                hasConfirmedNonASCII = true
                performSave()
            }
        } message: {
            Text("""
            These fields contain characters outside the standard keyboard set:

            \(nonASCIIWarningMessage)

            This is usually a Chinese input method producing a full-width ！ instead of !. The field is masked, so it looks correct, and the gateway will simply reject the login. Switch the input method to English and retype the field.
            """)
        }
    }

    private func load() {
        if let existing = (try? configStore.load()) ?? nil {
            config = existing
            originalConfig = existing
        }
    }

    private func save() {
        // Warn before saving, not after: once stored, a full-width ！ is
        // invisible in the masked field and the gateway only ever says 401.
        if !config.suspiciousCredentialFields.isEmpty, !hasConfirmedNonASCII {
            nonASCIIWarningMessage = config.suspiciousCredentialFields
                .map { field, scalars in
                    let shown = scalars.prefix(6).map { String($0) }.joined(separator: " ")
                    return "\(field): \(shown)"
                }
                .joined(separator: "\n")
            showNonASCIIWarning = true
            return
        }
        performSave()
    }

    private func performSave() {
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
