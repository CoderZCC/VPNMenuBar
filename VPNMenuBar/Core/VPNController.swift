import Foundation
import Combine
import UserNotifications

@MainActor
final class VPNController: ObservableObject {

    @Published private(set) var state: VPNState = .disconnected
    @Published private(set) var lastDependencyStatuses: [DependencyStatus] = []

    private let configStore: ConfigStore
    private let dependencyChecker: DependencyChecker
    private let openConnectProcess: OpenConnectProcessRunning
    private let networkMonitor: NetworkMonitoring
    /// Minimum life a TOTP code must have left before we hand it to openconnect.
    private static let minTOTPValidity = 8

    /// ocserv runs fail2ban: a handful of failed auth attempts from one source
    /// IP gets it banned for ~10 minutes, and the ban surfaces as a TLS reset
    /// mid-handshake — an error that looks nothing like "you were rate limited".
    /// Stop the user from digging that hole by clicking Connect repeatedly.
    private static let failuresBeforeCooldown = 3
    private static let cooldownSeconds: TimeInterval = 300

    private var consecutiveFailures = 0
    private var cooldownUntil: Date?

    private let handshakeTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private var monitorTask: Task<Void, Never>?

    /// User's intent flag: true once the user has successfully connected, stays true
    /// across auto-disconnects caused by network loss so we can reconnect when the
    /// network comes back. Cleared on explicit user-initiated disconnect.
    private var shouldAutoReconnect: Bool = false

    init(
        configStore: ConfigStore,
        dependencyChecker: DependencyChecker,
        openConnectProcess: OpenConnectProcessRunning,
        networkMonitor: NetworkMonitoring = NetworkMonitor(),
        handshakeTimeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 2.0
    ) {
        self.configStore = configStore
        self.dependencyChecker = dependencyChecker
        self.openConnectProcess = openConnectProcess
        self.networkMonitor = networkMonitor
        self.handshakeTimeout = handshakeTimeout
        self.pollInterval = pollInterval
    }

    /// Wires up the network reachability callback and starts monitoring.
    /// Called from AppCoordinator AFTER the XCTest-host guard so tests don't
    /// start a real system-wide network watcher.
    func startNetworkMonitoring() {
        networkMonitor.onChange = { [weak self] reachable in
            Task { @MainActor [weak self] in
                await self?.handleNetworkChange(reachable: reachable)
            }
        }
        networkMonitor.onInterfaceChange = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleInterfaceChange()
            }
        }
        networkMonitor.start()
    }

    /// Primary network interface changed (e.g. WiFi A → WiFi B) without an
    /// intermediate unreachable state. The openconnect child is still alive
    /// but its tunnel is bound to the previous interface and cannot route, so
    /// drop it and let the auto-reconnect path bring it back on the new
    /// interface (which also runs cleanupStaleHostRoute — see Quirk #11).
    private func handleInterfaceChange() async {
        AppLogger.shared.info("interface change detected (state=\(state))")
        guard case .connected = state else { return }
        await autoDisconnect()
        if shouldAutoReconnect {
            await connect()
        }
    }

    private func handleNetworkChange(reachable: Bool) async {
        AppLogger.shared.info("network change: reachable=\(reachable) state=\(state) shouldAutoReconnect=\(shouldAutoReconnect)")
        if reachable {
            // Network came back — auto-reconnect if the user had previously been
            // intentionally connected (shouldAutoReconnect flag set).
            if shouldAutoReconnect, case .disconnected = state {
                await connect()
            }
        } else {
            // Network vanished — if we're currently connected, proactively drop the
            // tunnel so openconnect doesn't hang on a dead transport. Preserve the
            // intent flag so recovery triggers a reconnect.
            if case .connected = state {
                await autoDisconnect()
            }
        }
    }

    // MARK: - Public API

    func connect() async {
        AppLogger.shared.info("connect() invoked")
        if let until = cooldownUntil, Date() < until {
            let wait = Int(until.timeIntervalSinceNow.rounded(.up))
            AppLogger.shared.warn("connect blocked — cooldown active for another \(wait)s after \(consecutiveFailures) failures")
            state = .failed(reason: "Too many failed attempts. Waiting \(wait)s before retrying so the server doesn't ban this IP.")
            return
        }
        guard let config = (try? configStore.load()), config.isConfigured else {
            AppLogger.shared.warn("connect aborted — setup incomplete")
            state = .failed(reason: "Setup incomplete — open Settings to finish configuration.")
            return
        }
        // otpSeparate + secret lengths are logged because a stdin/auth-form
        // mismatch is indistinguishable from a protocol error in openconnect's
        // stderr — never log the values themselves.
        AppLogger.shared.info("config loaded — user=\(config.username) gateway=\(config.gateway) openconnect=\(config.openconnectPath) skipDNS=\(config.skipDNSModification) otpSeparate=\(config.otpSentSeparately ?? false) pwdPrefixLen=\(config.passwordPrefix.count) totpSecretLen=\(config.totpSecret.count) userAgent=\(config.effectiveUserAgent ?? "<openconnect default>")")

        let checker = dependencyChecker
        let statuses = await Task.detached(priority: .userInitiated) {
            checker.check(config: config)
        }.value
        lastDependencyStatuses = statuses
        let depsSummary = statuses.map { "\($0.id)=\($0.passed ? "ok" : "fail")" }.joined(separator: " ")
        AppLogger.shared.info("dependency check: \(depsSummary)")
        if let failed = statuses.first(where: { !$0.passed }) {
            AppLogger.shared.error("connect blocked — dependency \(failed.id) failed: \(failed.detail)")
            state = .failed(reason: "Dependency not ready: \(failed.detail)")
            return
        }

        state = .connecting

        // Don't mint a code that is about to expire — see
        // TOTPGenerator.secondsRemainingInStep. Waiting out the tail costs at
        // most `minTOTPValidity` seconds and is invisible next to the handshake.
        let remaining = TOTPGenerator.secondsRemainingInStep()
        if remaining < Self.minTOTPValidity {
            AppLogger.shared.info("TOTP step has \(remaining)s left — waiting for the next one")
            try? await Task.sleep(nanoseconds: UInt64(remaining) * 1_000_000_000 + 200_000_000)
        }

        let code: String
        do {
            code = try TOTPGenerator.code(secret: config.totpSecret)
        } catch {
            AppLogger.shared.error("TOTP generation failed: \(error)")
            state = .failed(reason: "Invalid TOTP secret — please check Settings.")
            return
        }
        // The code itself is logged on purpose: comparing it against the
        // authenticator app at the same instant is the only way to tell a bad
        // secret apart from a server-side rejection. It expires in <30s, and
        // the secret that produced it is never logged.
        let now = Date()
        AppLogger.shared.info("TOTP generated: code=\(code) counter=\(UInt64(now.timeIntervalSince1970 / TOTPGenerator.step)) unixTime=\(UInt64(now.timeIntervalSince1970)) validFor=\(TOTPGenerator.secondsRemainingInStep(at: now))s localTime=\(now)")
        // Two-step gateways expect the OTP as a second stdin line (see
        // VPNConfig.otpSentSeparately); classic gateways expect one
        // concatenated password.
        let password = (config.otpSentSeparately ?? false)
            ? config.passwordPrefix + "\n" + code
            : config.passwordPrefix + code

        let proc = openConnectProcess
        do {
            try await Task.detached(priority: .userInitiated) {
                try proc.start(config: config, password: password)
            }.value
        } catch {
            AppLogger.shared.error("openconnect spawn failed: \(error)")
            state = .failed(reason: "Failed to launch openconnect. Verify the openconnect path in Settings → Advanced.")
            return
        }

        let handshakeStart = Date()
        let outcome = await openConnectProcess.waitForHandshake(timeout: handshakeTimeout)
        // Elapsed time tells apart "the code expired in flight" (would need to
        // be seconds) from "the server rejected it outright" (milliseconds).
        let elapsedMs = Int(Date().timeIntervalSince(handshakeStart) * 1000)
        AppLogger.shared.info("handshake finished in \(elapsedMs)ms, TOTP had \(TOTPGenerator.secondsRemainingInStep())s left at completion")
        switch outcome {
        case .connected:
            AppLogger.shared.info("handshake succeeded — VPN connected")
            consecutiveFailures = 0
            cooldownUntil = nil
            state = .connected(since: Date())
            shouldAutoReconnect = true    // user is intentionally connected
            startMonitoring()
        case .failed(let reason):
            AppLogger.shared.error("handshake failed: \(reason)")
            await logClockOffset()
            consecutiveFailures += 1
            if consecutiveFailures >= Self.failuresBeforeCooldown {
                cooldownUntil = Date().addingTimeInterval(Self.cooldownSeconds)
                AppLogger.shared.warn("\(consecutiveFailures) consecutive failures — cooling down \(Int(Self.cooldownSeconds))s to avoid a fail2ban lockout")
            }
            // CRITICAL: on handshake failure openconnect may have left a
            // zombie child that already ran vpnc-script's connect phase
            // (DNS and route table mutated) without ever reaching the
            // disconnect phase. Without a SIGTERM here those mutations
            // strand the whole machine's networking until the user quits
            // the app. Send the kill now so vpnc-script's disconnect phase
            // restores DNS and routes.
            let proc = openConnectProcess
            _ = await Task.detached(priority: .userInitiated) {
                try? proc.stop()
            }.value
            AppLogger.shared.info("post-failure cleanup: sent SIGTERM to any residual openconnect")
            state = .failed(reason: reason)
            // Don't auto-reconnect on failed initial connects (wrong creds, missing deps).
        }
    }

    /// Query an NTP server and log how far this Mac's clock has drifted.
    ///
    /// A TOTP code is derived from the local clock, so a machine that is more
    /// than ~30s off generates codes the gateway rejects outright — which is
    /// indistinguishable from a wrong secret in openconnect's output. Only run
    /// on failure: it costs a network round trip. `sntp` needs no root as long
    /// as we don't ask it to set the clock.
    private func logClockOffset() async {
        let result = await Task.detached(priority: .utility) { () -> ProcessResult? in
            try? SystemProcessRunner().run(
                executable: "/usr/bin/sntp",
                arguments: ["-t", "3", "time.apple.com"],
                timeoutSeconds: 5
            )
        }.value
        // sntp writes the offset line to stdout on success but to stderr on
        // lookup failure — keep both so a failed query is still diagnosable.
        let text = [result?.stdout, result?.stderr]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        AppLogger.shared.info("clock offset check (sntp): \(text.isEmpty ? "<no output — query failed>" : text)")
    }

    /// User-initiated disconnect. Clears the auto-reconnect intent.
    func disconnect() async {
        AppLogger.shared.info("disconnect() invoked by user")
        shouldAutoReconnect = false
        await performDisconnect()
    }

    /// System-initiated disconnect (e.g. network loss). Preserves the auto-reconnect
    /// intent so we can resume when the network comes back.
    private func autoDisconnect() async {
        AppLogger.shared.warn("autoDisconnect triggered (network change / interface switch)")
        await performDisconnect()
    }

    private func performDisconnect() async {
        monitorTask?.cancel()
        monitorTask = nil
        let proc = openConnectProcess
        _ = await Task.detached(priority: .userInitiated) {
            try? proc.stop()
        }.value
        state = .disconnected
    }

    func reconnect() async {
        await disconnect()
        await connect()
    }

    /// Called when the user dismisses the Onboarding window without completing setup.
    /// Per spec §5.3, puts the app into a "Setup incomplete" failed state.
    func markSetupIncomplete() {
        state = .failed(reason: "Setup incomplete — open Settings to finish configuration.")
    }

    func checkDependencies() -> [DependencyStatus] {
        // Use saved config when available; otherwise fall back to a default so the
        // Onboarding dependency step can still probe the default openconnect and
        // vpnc-script paths before the user has filled in credentials.
        let config = (try? configStore.load())
            ?? VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
        let statuses = dependencyChecker.check(config: config)
        lastDependencyStatuses = statuses
        return statuses
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitorTask?.cancel()
        let interval = pollInterval
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                let stillRunning = self.openConnectProcess.isRunning()
                let tail = stillRunning ? "" : self.openConnectProcess.recentStderrTail(bytes: 600)
                await MainActor.run {
                    if !stillRunning, case .connected = self.state {
                        if tail.isEmpty {
                            AppLogger.shared.error("watchdog: openconnect child vanished unexpectedly — transitioning to disconnected (no stderr captured)")
                        } else {
                            AppLogger.shared.error("watchdog: openconnect child vanished unexpectedly — transitioning to disconnected. stderr tail:\n\(tail)")
                        }
                        self.state = .disconnected
                        Self.postUnexpectedDisconnectNotification()
                    }
                }
                if !stillRunning { return }
            }
        }
    }

    private static func postUnexpectedDisconnectNotification() {
        let content = UNMutableNotificationContent()
        content.title = "VPN disconnected"
        content.body = "The VPN connection ended unexpectedly."
        let request = UNNotificationRequest(
            identifier: "com.example.vpnmenubar.unexpected-disconnect",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
