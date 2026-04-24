import Foundation
import ServiceManagement

/// Manages the "Launch at login" feature.
///
/// The user's preference is stored in UserDefaults so that the default-on behavior
/// survives a missing SMAppService entry (e.g. after moving the .app bundle) while
/// still respecting an explicit user opt-out. On first launch (preference key missing)
/// the default is `true` — the app registers itself as a login item automatically.
enum LoginItemManager {
    private static let preferenceKey = "launchAtLoginEnabled"

    /// User's stored preference. Defaults to `true` on first launch.
    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: preferenceKey) == nil {
                return true
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
