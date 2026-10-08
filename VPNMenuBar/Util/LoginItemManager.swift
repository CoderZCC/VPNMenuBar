import Foundation
import ServiceManagement

/// Manages the "Launch at login" feature.
///
/// Login items are opt-in. Existing explicit preferences remain respected.
enum LoginItemManager {
    private static let preferenceKey = "launchAtLoginEnabled"

    /// User's stored preference. Defaults to `false` on first launch.
    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: preferenceKey) == nil {
                return false
            }
            return defaults.bool(forKey: preferenceKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: preferenceKey)
            applyToSystem(newValue)
        }
    }

    /// Call once at app launch to sync the stored preference to SMAppService.
    /// No-op if the system already matches the preference.
    static func applyPreference() {
        applyToSystem(isEnabledPreference)
    }

    private static func applyToSystem(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            AppLogger.shared.error("LoginItemManager.applyToSystem(\(enabled)) failed: \(error)")
        }
    }
}
