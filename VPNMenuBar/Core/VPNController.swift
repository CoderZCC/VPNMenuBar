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

    /// connect() is @MainActor but suspends several times (dependency probe,
    /// TOTP wait, handshake). Two callers — say an auto-reconnect racing a menu
    /// click — would otherwise interleave through those suspension points and
    /// each spawn an openconnect, and `state = .connecting` is set too late to
    /// stop it. Worse, both mint the same TOTP code: the gateway accepts it once
    /// and rejects the replay with a 401 that looks exactly like a bad OTP.
    private var connectInFlight = false

    /// TOTP step already handed to the gateway. A code is single-use — reusing
    /// one inside its 30s window gets a 401 for replay, not for being wrong.
    ///
    /// Persisted, not held in memory: the app quitting and relaunching inside
    /// one 30s step is not an edge case, it is precisely what applying an update
    /// does — the old process authenticates, quits, and the new one auto-connects
    /// ~5s later with a blank in-memory guard. Observed 2026-08-21: v0.2.15
    /// connected with counter 59576323, the v0.2.16 process resubmitted the same
    /// counter 8s later, ocserv 401'd the replay and its fail2ban then reset the
    /// next two TLS handshakes. Stored in UserDefaults rather than VPNConfig to
    /// stay out of the Codable schema — same reasoning as launchAtLoginEnabled.
    private static let lastTOTPCounterKey = "lastSubmittedTOTPCounter"

    private var lastSubmittedTOTPCounter: UInt64? {
        get {
            (UserDefaults.standard.object(forKey: Self.lastTOTPCounterKey) as? NSNumber)?.uint64Value
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(NSNumber(value: newValue), forKey: Self.lastTOTPCounterKey)
            } else {
                defaults.removeObject(forKey: Self.lastTOTPCounterKey)
            }
        }
    }

    private let handshakeTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private var monitorTask: Task<Void, Never>?

    /// User's intent flag: true once the user has successfully connected, stays true
    /// across auto-disconnects caused by network loss so we can reconnect when the
    /// network comes back. Cleared on explicit user-initiated disconnect.
    private var shouldAutoReconnect: Bool = false

    /// Last reachability value reported by the network monitor. Lets the
    /// watchdog skip a doomed reconnect attempt (and its failure-counter cost)
    /// when the child died because the network itself is down — the
    /// reachability handler picks the reconnect up once the network returns.
    private var networkReachable = true

    /// Last time the watchdog auto-reconnected after an unexpected child death.
    /// The fail2ban cooldown only counts *failed* handshakes, so a gateway that
    /// accepts the handshake and then kills the session seconds later would
    /// loop spawn→die→respawn forever without ever tripping it. This throttle
    /// bounds that pattern to one attempt per interval.
    private var lastChildDeathReconnect: Date?
    private static let childDeathReconnectMinInterval: TimeInterval = 60

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
        networkReachable = reachable
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
        // No await between the check and the set — on the main actor that makes
        // this a real mutex, not a check-then-act race.
        guard !connectInFlight else {
            AppLogger.shared.warn("connect ignored — an attempt is already in flight")
            return
        }
        connectInFlight = true
        defer { connectInFlight = false }

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
        if let odd = config.nonASCIICredentialSummary {
            AppLogger.shared.warn("non-ASCII characters in credentials — likely a CJK input-method slip (full-width ！ for !): \(odd)")
        }

        let checker = dependencyChecker
        let statuses = await Task.detached(priority: .userInitiated) {
            checker.check(config: config)
        }.value
        lastDependencyStatuses = statuses
        let depsSummary = statuses.map { s -> String in
            let verdict = s.passed ? "ok" : (s.isSkipped ? "skip" : "fail")
            return "\(s.id)=\(verdict)"
        }.joined(separator: " ")
        AppLogger.shared.info("dependency check: \(depsSummary)")
        if let failed = statuses.first(where: { !$0.passed && !$0.isSkipped })
            ?? statuses.first(where: { !$0.passed }) {
            AppLogger.shared.error("connect blocked — dependency \(failed.id) failed: \(failed.detail)")
            state = .failed(reason: "Dependency not ready: \(failed.detail)")
            return
        }

        state = .connecting

        // Wait out the current TOTP step when it is nearly over (the code could
        // expire in flight) or when we already submitted it (the gateway treats
        // a reused code as a replay and answers 401, which is indistinguishable
        // from a wrong OTP). Costs at most one step.
        let remaining = TOTPGenerator.secondsRemainingInStep()
        let currentCounter = UInt64(Date().timeIntervalSince1970 / TOTPGenerator.step)
        let alreadySubmitted = lastSubmittedTOTPCounter == currentCounter
        if alreadySubmitted || remaining < Self.minTOTPValidity {
            let why = alreadySubmitted ? "code \(currentCounter) was already submitted" : "only \(remaining)s left"
            AppLogger.shared.info("waiting \(remaining)s for the next TOTP step — \(why)")
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
        let counter = UInt64(now.timeIntervalSince1970 / TOTPGenerator.step)
        lastSubmittedTOTPCounter = counter
        AppLogger.shared.info("TOTP generated: code=\(code) counter=\(counter) unixTime=\(UInt64(now.timeIntervalSince1970)) validFor=\(TOTPGenerator.secondsRemainingInStep(at: now))s localTime=\(now)")
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
                let didTransition = await MainActor.run { () -> Bool in
                    guard !stillRunning, case .connected = self.state else { return false }
                    if tail.isEmpty {
                        AppLogger.shared.error("watchdog: openconnect child vanished unexpectedly — transitioning to disconnected (no stderr captured)")
                    } else {
                        AppLogger.shared.error("watchdog: openconnect child vanished unexpectedly — transitioning to disconnected. stderr tail:\n\(tail)")
                    }
                    self.state = .disconnected
                    Self.postUnexpectedDisconnectNotification()
                    return true
                }
                if !stillRunning {
                    if didTransition {
                        await self.reconnectAfterChildDeath()
                    }
                    return
                }
            }
        }
    }

    /// The openconnect child died while we believed we were connected — most
    /// commonly the machine slept past ocserv's cookie timeout, openconnect's
    /// own resume got a 401 and it exited. A fresh connect() (full re-auth,
    /// new TOTP) is the fix, so do it automatically when the user's intent
    /// flag is set. If the network is down, defer to handleNetworkChange —
    /// spawning openconnect against a dead network would only burn a
    /// failure-counter slot toward the fail2ban cooldown. A *failed* reconnect
    /// does not loop (connect() failure doesn't restart the watchdog, and the
    /// cooldown counts it); a *succeeding-then-dying* one would — hence the
    /// min-interval throttle on top.
    private func reconnectAfterChildDeath() async {
        guard shouldAutoReconnect else { return }
        guard networkReachable else {
            AppLogger.shared.info("watchdog: network unreachable — deferring auto-reconnect to the reachability handler")
            return
        }
        if let last = lastChildDeathReconnect,
           Date().timeIntervalSince(last) < Self.childDeathReconnectMinInterval {
            AppLogger.shared.warn("watchdog: child died again within \(Int(Self.childDeathReconnectMinInterval))s of the last auto-reconnect — gateway looks unstable, staying disconnected")
            return
        }
        lastChildDeathReconnect = Date()
        AppLogger.shared.info("watchdog: auto-reconnecting after unexpected child exit")
        await connect()
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
