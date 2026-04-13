import Foundation

struct VPNConfig: Codable, Equatable {
    // Required — collected by Onboarding
    var username: String
    var passwordPrefix: String
    var totpSecret: String

    // Required — VPN server settings (user must fill in their own values)
    var gateway: String = ""
    var serverCertPin: String = ""
    var openconnectPath: String = ArchDetector.defaultPaths.openconnect
    var vpncScriptPath: String = ArchDetector.defaultPaths.vpncScript
    var skipDNSModification: Bool = true

    // Meta
    var schemaVersion: Int = 1

    var isConfigured: Bool {
        !username.isEmpty && !passwordPrefix.isEmpty && !totpSecret.isEmpty
            && !gateway.isEmpty && !serverCertPin.isEmpty
    }
}
