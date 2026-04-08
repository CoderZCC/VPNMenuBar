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
        networkMonitor.start()
    }

    private func handleNetworkChange(reachable: Bool) async {
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
        guard let config = (try? configStore.load()), config.isConfigured else {
            state = .failed(reason: "Setup incomplete — open Settings to finish configuration.")
            return
        }

        let checker = dependencyChecker
        let statuses = await Task.detached(priority: .userInitiated) {
            checker.check(config: config)
        }.value
        lastDependencyStatuses = statuses
        if let failed = statuses.first(where: { !$0.passed }) {
            state = .failed(reason: "Dependency not ready: \(failed.detail)")
            return
        }

        state = .connecting

        let code: String
        do {
            code = try TOTPGenerator.code(secret: config.totpSecret)
        } catch {
            state = .failed(reason: "Invalid TOTP secret — please check Settings.")
            return
        }
        let password = config.passwordPrefix + code

        let proc = openConnectProcess
        do {
            try await Task.detached(priority: .userInitiated) {
                try proc.start(config: config, password: password)
            }.value
        } catch {
            state = .failed(reason: "Failed to launch openconnect. Verify the openconnect path in Settings → Advanced.")
            return
        }

        let outcome = await openConnectProcess.waitForHandshake(timeout: handshakeTimeout)
        switch outcome {
        case .connected:
            state = .connected(since: Date())
            shouldAutoReconnect = true    // user is intentionally connected
            startMonitoring()
        case .failed(let reason):
            state = .failed(reason: reason)
            // Don't auto-reconnect on failed initial connects (wrong creds, missing deps).
        }
    }

    /// User-initiated disconnect. Clears the auto-reconnect intent.
    func disconnect() async {
        shouldAutoReconnect = false
        await performDisconnect()
    }

    /// System-initiated disconnect (e.g. network loss). Preserves the auto-reconnect
    /// intent so we can resume when the network comes back.
    private func autoDisconnect() async {
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
                await MainActor.run {
                    if !stillRunning, case .connected = self.state {
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
