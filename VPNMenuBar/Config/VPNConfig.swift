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

    // Two-step gateways (e.g. ocserv) send a second auth form asking for the
    // OTP after the password is accepted. When true, the password and TOTP are
    // written to openconnect's stdin as two separate lines instead of being
    // concatenated into one. Optional so configs saved before this field
    // existed still decode (nil == false).
    var otpSentSeparately: Bool? = nil

    // Some gateways route clients by User-Agent: openconnect's own
    // "Open AnyConnect VPN Agent v9.x" gets served an HTTP Basic challenge
    // instead of the OTP form, so the second auth step always fails with 401
    // while the official Cisco client — which sends the string below — works.
    // Optional so pre-existing configs pick up the default on upgrade; empty
    // string means "send openconnect's own UA".
    var userAgent: String? = nil

    static let defaultUserAgent = "AnyConnect Windows 4.10.06079"

    /// The UA to actually pass to openconnect, or nil to leave it alone.
    var effectiveUserAgent: String? {
        guard let ua = userAgent else { return VPNConfig.defaultUserAgent }
        return ua.isEmpty ? nil : ua
    }

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
        copy.userAgent = userAgent.map { VPNConfig.cleanField($0) }
        return copy
    }

    /// Characters outside printable ASCII in a credential field.
    ///
    /// A CJK input method turns `!` into the full-width `！` (U+FF01). Both are
    /// one character, so a length check can't see it, `cleanField` won't strip
    /// it (it is neither invisible nor a control character), and a masked field
    /// renders both as the same dot. The gateway just answers 401. Surfacing
    /// this is the only way a user can catch it.
    static func nonASCIICharacters(in value: String) -> [Unicode.Scalar] {
        value.unicodeScalars.filter { $0.value < 0x20 || $0.value > 0x7E }
    }

    /// Credential fields containing non-ASCII characters, for a save-time warning.
    var suspiciousCredentialFields: [(field: String, characters: [Unicode.Scalar])] {
        [("Username", username),
         ("Password prefix", passwordPrefix),
         ("TOTP secret", totpSecret)]
            .compactMap { name, value in
                let bad = VPNConfig.nonASCIICharacters(in: value)
                return bad.isEmpty ? nil : (name, bad)
            }
    }

    /// Compact summary for the log: field name + code points, never the field
    /// itself. An isolated code point does not meaningfully leak the secret and
    /// it is the one detail that makes this failure diagnosable from a log.
    var nonASCIICredentialSummary: String? {
        let hits = suspiciousCredentialFields
        guard !hits.isEmpty else { return nil }
        return hits.map { field, scalars in
            let codes = scalars.prefix(3)
                .map { String(format: "U+%04X", $0.value) }
                .joined(separator: ",")
            return "\(field)=[\(codes)\(scalars.count > 3 ? ",…" : "")]"
        }.joined(separator: " ")
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
