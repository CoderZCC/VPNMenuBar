import Foundation

/// Stores the "auto-connect on launch" preference in UserDefaults.
/// Default is `false` (opt-in) — auto-connecting without user consent would be
/// intrusive given the sudo prompt cascade on a misconfigured machine.
enum AutoConnectPreference {
    private static let preferenceKey = "autoConnectOnLaunchEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }
}
