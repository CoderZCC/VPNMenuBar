import Foundation

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// True when the failure reason indicates the user hasn't finished Onboarding.
    /// Used by the menu to lock down all actions except "Check Dependencies…".
    var isSetupIncomplete: Bool {
        if case .failed(let reason) = self {
            return reason.hasPrefix("Setup incomplete")
        }
        return false
    }

    /// Short human-readable label for menu display.
    var shortLabel: String {
        switch self {
        case .disconnected:       return "Disconnected"
        case .connecting:         return "Connecting…"
        case .connected:          return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}
