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

    /// Strip surrounding whitespace and invisible characters (zero-width, BOM,
    /// newlines, NBSP, ideographic space) that commonly get pasted in from
    /// chat apps / PDFs and silently break `openconnect` arguments.
    func sanitized() -> VPNConfig {
        var copy = self
        copy.username = VPNConfig.cleanField(username)
        copy.passwordPrefix = VPNConfig.cleanField(passwordPrefix)
        copy.totpSecret = VPNConfig.cleanField(totpSecret)
        copy.gateway = VPNConfig.cleanField(gateway)
        copy.serverCertPin = VPNConfig.cleanField(serverCertPin)
        copy.openconnectPath = VPNConfig.cleanField(openconnectPath)
        copy.vpncScriptPath = VPNConfig.cleanField(vpncScriptPath)
        return copy
    }

    private static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}",
        "\u{2028}", "\u{2029}", "\u{00A0}", "\u{3000}",
    ]

    private static func cleanField(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            if invisibleScalars.contains(scalar) { return false }
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
