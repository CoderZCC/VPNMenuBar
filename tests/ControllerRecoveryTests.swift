import Foundation
import Security

private final class Credentials: CredentialStoring {
    var items: [String: VPNCredentials] = [:]
    var error: OSStatus?
    func read(reference: String) throws -> VPNCredentials {
        if let error { throw CredentialStoreError.keychain(error) }
        guard let value = items[reference] else { throw CredentialStoreError.keychain(errSecItemNotFound) }
        return value
    }
    func add(_ credentials: VPNCredentials, reference: String) throws { items[reference] = credentials }
    func delete(reference: String) throws { items.removeValue(forKey: reference) }
}

private final class FailingDependencies: DependencyChecker {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    override func check(config: VPNConfig) -> [DependencyStatus] {
        lock.lock(); count += 1; lock.unlock()
        // Stop before TOTP, sudo, process creation or network I/O.
        return [DependencyStatus(id: .openconnect, passed: false, detail: "fixture failure",
                                 fixHint: "", fixCommand: nil, inAppFix: nil)]
    }
}

private final class NoVPN: OpenConnectProcessRunning {
    func start(config: VPNConfig, password: String) throws { fatalError("Must not start a VPN") }
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake { fatalError("Must not authenticate") }
    func isRunning() -> Bool { false }
    func recentStderrTail(bytes: Int) -> String { "" }
    func stop() throws { }
}

private final class ReadyDependencies: DependencyChecker {
    override func check(config: VPNConfig) -> [DependencyStatus] { [] }
}

private final class AuthorizationCancelledVPN: OpenConnectProcessRunning {
    var preparations = 0
    func prepare(config: VPNConfig) throws {
        preparations += 1
        throw DependencyInstallError.userCancelled
    }
    func start(config: VPNConfig, password: String) throws { fatalError("Cancelled authorization must not send credentials") }
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake { fatalError("Cancelled authorization must not authenticate") }
    func isRunning() -> Bool { false }
    func recentStderrTail(bytes: Int) -> String { "" }
    func stop() throws { }
}

private final class StuckVPN: OpenConnectProcessRunning {
    func start(config: VPNConfig, password: String) throws { fatalError("Not a connection fixture") }
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake { fatalError("Not a connection fixture") }
    func isRunning() -> Bool { true }
    func recentStderrTail(bytes: Int) -> String { "" }
    func stop() throws { throw DependencyInstallError.unsupported(reason: "fixture stop failure") }
}

private final class Network: NetworkMonitoring {
    var onChange: ((Bool) -> Void)?
    var onInterfaceChange: (() -> Void)?
    func start() { }
    func stop() { }
}

@main
struct ControllerRecoveryTests {
    @MainActor
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credentials = Credentials()
        let store = ConfigStore(baseDirectory: dir, credentials: credentials)
        var config = VPNConfig(username: "fixture", passwordPrefix: "fixture-password", totpSecret: "fixture-secret")
        config.gateway = "vpn.example.com"
        config.serverCertPin = "fixture-pin"
        try store.save(config)
        let deps = FailingDependencies()
        let network = Network()
        let controller = VPNController(configStore: store, dependencyChecker: deps, openConnectProcess: NoVPN(),
                                       networkMonitor: network, credentialRetryInterval: 0.01)
        controller.startNetworkMonitoring()
        credentials.error = errSecInteractionNotAllowed
        await controller.connect()
        precondition(controller.waitingForCredentials)
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(deps.calls == 0, "Locked storage must not reach authentication/dependencies")
        credentials.error = nil
        for _ in 0..<100 where deps.calls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(deps.calls == 1, "Unlock resumes one connection")
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(deps.calls == 1 && !controller.waitingForCredentials, "Connection failure must not loop")
        print("PASS: unlock resumes once, no network attempts while locked or after connection failure")

        credentials.error = errSecInteractionNotAllowed
        await controller.connect()
        await controller.disconnect()
        credentials.error = nil
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(deps.calls == 1 && !controller.waitingForCredentials, "User cancellation fences stale retry")
        print("PASS: cancellation prevents delayed reconnect")

        credentials.error = errSecInteractionNotAllowed
        await controller.connect()
        network.onChange?(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        credentials.error = nil
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(deps.calls == 1, "No reconnect while offline")
        network.onChange?(true)
        for _ in 0..<100 where deps.calls == 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(deps.calls == 2, "Pending unlock recovery survives offline/online transition")
        print("PASS: offline wait resumes after reachability returns")

        for status in [errSecItemNotFound, errSecMissingEntitlement, errSecAuthFailed] {
            credentials.error = status
            await controller.connect()
            precondition(!controller.waitingForCredentials, "Permanent failure must not retry")
        }
        credentials.error = errSecNotAvailable
        await controller.connect()
        precondition(controller.waitingForCredentials)
        credentials.error = errSecItemNotFound
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(!controller.waitingForCredentials && deps.calls == 2)
        print("PASS: permanent errors stop pending recovery")
        await controller.disconnect()

        credentials.error = nil
        let cancelledVPN = AuthorizationCancelledVPN()
        let cancelled = VPNController(configStore: store, dependencyChecker: ReadyDependencies(),
                                      openConnectProcess: cancelledVPN, networkMonitor: Network())
        await cancelled.connect()
        precondition(cancelled.state == .failed(reason: "Authorization cancelled."))
        precondition(cancelledVPN.preparations == 1 && !cancelled.hasActiveProcess && !cancelled.waitingForCredentials)
        print("PASS: authorization cancellation stops before credential submission or handshake")

        let stuck = VPNController(configStore: store, dependencyChecker: ReadyDependencies(),
                                  openConnectProcess: StuckVPN(), networkMonitor: Network())
        await stuck.disconnect()
        if case .failed = stuck.state {} else { fatalError("Failed stop must not report disconnected") }
        precondition(stuck.hasActiveProcess, "Quit must remain blocked while the VPN is still active")
        print("PASS: failed teardown preserves active-process state for quit handling")
    }
}
