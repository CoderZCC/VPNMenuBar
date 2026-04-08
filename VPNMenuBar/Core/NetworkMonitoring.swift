import Foundation
import Network

/// Observes system network reachability. Callers set `onChange` to receive
/// reachability flips; callbacks are delivered on the monitor's internal serial
/// queue and consumers are responsible for hopping to their own actor if needed.
protocol NetworkMonitoring: AnyObject {
    /// Called when reachability toggles between reachable (true) and unreachable (false).
    /// Not called for successive same-value updates.
    var onChange: ((Bool) -> Void)? { get set }
    /// Called when the primary network interface changes while still reachable
    /// (e.g. WiFi A → WiFi B roam, WiFi → Ethernet) without an intermediate
    /// unreachable state. Consumers should treat this as "tunnel transport
    /// changed underneath us, drop and reconnect".
    var onInterfaceChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Production implementation backed by `NWPathMonitor`.
final class NetworkMonitor: NetworkMonitoring {
    var onChange: ((Bool) -> Void)?
    var onInterfaceChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private let callbackQueue = DispatchQueue(label: "com.example.vpnmenubar.network-monitor")
    private var lastReachable: Bool?
    private var lastPrimaryInterface: String?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let reachable = (path.status == .satisfied)
            // Primary = first non-loopback interface in availableInterfaces.
            // utun* (the VPN tunnel itself) must be excluded — otherwise after
            // openconnect brings up utunN it becomes the "primary" and every
            // subsequent path update looks like an interface change.
            let primary = path.availableInterfaces.first(where: { iface in
                iface.type != .loopback && !iface.name.hasPrefix("utun")
            })?.name
            let reachabilityFlipped = (self.lastReachable != reachable)
            let interfaceChanged = (reachable
                && self.lastReachable == true
                && primary != nil
                && self.lastPrimaryInterface != nil
                && primary != self.lastPrimaryInterface)
            self.lastReachable = reachable
            self.lastPrimaryInterface = primary
            if reachabilityFlipped {
                self.onChange?(reachable)
            } else if interfaceChanged {
                self.onInterfaceChange?()
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
