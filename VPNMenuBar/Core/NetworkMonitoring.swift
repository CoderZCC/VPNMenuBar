import Foundation
import Network

/// Observes system network reachability. Callers set `onChange` to receive
/// reachability flips; callbacks are delivered on the monitor's internal serial
/// queue and consumers are responsible for hopping to their own actor if needed.
protocol NetworkMonitoring: AnyObject {
    /// Called when reachability toggles between reachable (true) and unreachable (false).
    /// Not called for successive same-value updates.
    var onChange: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Production implementation backed by `NWPathMonitor`.
final class NetworkMonitor: NetworkMonitoring {
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private let callbackQueue = DispatchQueue(label: "com.example.vpnmenubar.network-monitor")
    private var lastReachable: Bool?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = (path.status == .satisfied)
            if self.lastReachable != reachable {
                self.lastReachable = reachable
                self.onChange?(reachable)
            }
        }
        monitor.start(queue: callbackQueue)
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.cancel()
    }
}
