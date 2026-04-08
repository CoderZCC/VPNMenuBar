import Foundation

struct VPNConfig: Codable, Equatable {
    // Required — collected by Onboarding
    var username: String
    var passwordPrefix: String
    var totpSecret: String

    // Advanced — defaults migrated from vpn.py / arch-aware
    var gateway: String = "vpn.example.com"
    var serverCertPin: String = "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    var openconnectPath: String = ArchDetector.defaultPaths.openconnect
    var vpncScriptPath: String = ArchDetector.defaultPaths.vpncScript
    var skipDNSModification: Bool = true

    // Meta
    var schemaVersion: Int = 1

    var isConfigured: Bool {
        !username.isEmpty && !passwordPrefix.isEmpty && !totpSecret.isEmpty
    }
}
