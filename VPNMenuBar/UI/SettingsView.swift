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
    /// Edited as text rather than bound through parse/format, so an
    /// in-progress line (a domain typed before its nameserver) is not
    /// rewritten under the cursor.
    @State private var resolverRulesText: String = ""

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

            Section("Intranet DNS rules") {
                // TextEditor has no placeholder, so it gets one drawn on top.
                // Prefilling the editor itself would make the user delete the
                // example before typing.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $resolverRulesText)
                        // Small monospaced: a rule is domain + IPv4, which must
                        // fit one line or the list stops being readable.
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled(true)
                        .padding(EdgeInsets(top: 4, leading: 3, bottom: 4, trailing: 3))
                        .onChange(of: resolverRulesText) { newValue in
                            config.resolverRules = ResolverRule.parse(newValue)
                        }
                    if resolverRulesText.isEmpty {
                        Text(verbatim: "portal.intranet.example.com  10.0.0.53")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(Color(nsColor: .placeholderTextColor))
                            .lineLimit(1)
                            .padding(EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 0))
                            .allowsHitTesting(false)
                    }
                }
                // Match the bordered TextFields above — a bare TextEditor in a
                // Form has no border at all and reads as unfinished.
                .frame(height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .help(
                    "One rule per line: <domain> <nameserver>, e.g. "
                        + "intranet.example.com 10.0.0.53\n\n"
                        + "Each rule becomes /etc/resolver/<domain>, so ONLY that domain is resolved "
                        + "by that nameserver — every other name keeps using the system resolver and "
                        + "the global DNS setting is left alone. Use the narrowest name that is "
                        + "actually internal: a parent domain also captures every host beneath it, "
                        + "including the VPN gateway itself, which would make reconnecting impossible "
                        + "while the VPN is down. Leave this empty unless an intranet name genuinely "
                        + "has no public DNS record. Install the files from Check Dependencies."
                    )
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
            resolverRulesText = ResolverRule.format(existing.resolverRules ?? [])
        }
    }

    private func save() {
        // DNS rules are validated before anything else: a rule that captures the
        // gateway's own hostname is the one setting in this window the user cannot
        // recover from without root, so it is a hard block, not a confirm-anyway warning.
        let parsed = ResolverRule.parseReportingErrors(resolverRulesText)
        if !parsed.badLines.isEmpty {
            savedAlertTitle = "Unrecognized DNS rule"
            let format: String = "Each line must be a domain and an IPv4 nameserver "
                + "separated by a space, e.g. \"intranet.example.com 10.0.0.53\"."
            let offending: String = parsed.badLines.joined(separator: "\n")
            savedAlertMessage = format + "\n\nThese lines were not understood:\n\n" + offending
            showSavedAlert = true
            return
        }
        let gatewayHost = OpenConnectProcess.extractHost(from: config.gateway)
        let dangerous = ResolverRule.rulesCapturingGateway(parsed.rules, gatewayHost: gatewayHost)
        if !dangerous.isEmpty {
            savedAlertTitle = "DNS rule would lock out the gateway"
            let names: String = dangerous.map { $0.domain }.joined(separator: ", ")
            let why: String = "macOS resolves by longest domain suffix, so the gateway's own "
                + "hostname would be sent to the intranet nameserver too — and that nameserver "
                + "is only reachable through the tunnel. With the VPN down the gateway would "
                + "stop resolving and this app could never reconnect."
            let advice: String = "Use the full hostname you need instead of the parent domain."
            savedAlertMessage = names + " also covers the VPN gateway " + gatewayHost
                + ".\n\n" + why + "\n\n" + advice
            showSavedAlert = true
            return
        }
        config.resolverRules = parsed.rules.isEmpty ? nil : parsed.rules

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
        } catch {
            AppLogger.shared.error("SettingsView save failed: \(error)")
            savedAlertTitle = "Save Failed"
            savedAlertMessage = "The config file may be read-only — check permissions under ~/Library/Application Support."
            showSavedAlert = true
            return
        }

        // Capture the window before the authorization dialog steals key status.
        let settingsWindow = NSApp.keyWindow
        let rules = config.resolverRules ?? []
        let gatewayHost = OpenConnectProcess.extractHost(from: config.gateway)
        // Writing the resolver files is part of saving the rules, not a second
        // errand in another window: asking the user to go find Check
        // Dependencies after typing a rule here is the whole reason this exists.
        // Nothing is asked for when the files already match, so an ordinary
        // save of unrelated settings never raises a prompt.
        let needsResolverWork = !ResolverFileManager.pendingRules(rules).isEmpty
            || !ResolverFileManager.orphanedDomains(keeping: rules).isEmpty

        // Resolver files have nothing to do with the tunnel, so a save that
        // only edits them must not bounce the VPN. Reconnecting anyway costs a
        // real outage: the TOTP replay guard makes the new connect wait out the
        // remainder of the 30s step (observed: 28s of downtime for a DNS-only
        // edit).
        var savedWithoutRules = config
        savedWithoutRules.resolverRules = nil
        var previousWithoutRules = originalConfig
        previousWithoutRules.resolverRules = nil
        let connectionSettingsChanged = savedWithoutRules != previousWithoutRules

        Task { @MainActor in
            if needsResolverWork {
                do {
                    try await ResolverFileManager.install(rules: rules, gatewayHost: gatewayHost)
                } catch DependencyInstallError.userCancelled {
                    // Silent: config is saved, the files simply aren't written.
                    // The dependency row stays red and either place can retry.
                } catch {
                    // Keep the window open so the alert is actually visible.
                    savedAlertTitle = "DNS rules not installed"
                    savedAlertMessage = error.localizedDescription
                        + "\n\nEverything else was saved. You can retry from Check Dependencies."
                    showSavedAlert = true
                    return
                }
            }
            settingsWindow?.close()
            guard connectionSettingsChanged else { return }
            if controller.state.isConnected {
                await controller.disconnect()
            }
            await controller.connect()
        }
    }
}
