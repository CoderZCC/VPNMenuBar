import Foundation

struct VPNConfig: Codable, Equatable {
    // Required — collected by Onboarding
    var username: String
    var passwordPrefix: String
    var totpSecret: String

    // Required — VPN server settings (user must fill in their own values)
    var gateway: String = ""
    var serverCertPin: String = ""
    var openconnectPath: String = ManagedRuntime.openconnect
    var vpncScriptPath: String = ManagedRuntime.script
    var skipDNSModification: Bool = true

    // Two-step gateways (e.g. ocserv) send a second auth form asking for the
    // OTP after the password is accepted. When true, the password and TOTP are
    // written to openconnect's stdin as two separate lines instead of being
    // concatenated into one. Optional so configs saved before this field
    // existed still decode (nil == false).
    var otpSentSeparately: Bool? = nil

    // Override only with the VPN administrator's approval; use the native UA by default.
    var userAgent: String? = nil
    static let defaultUserAgent = ""

    // Per-domain DNS overrides, written as /etc/resolver/<domain> files so that
    // ONLY those domains resolve via the intranet nameserver while every other
    // name keeps using the system resolver. Optional so pre-existing configs
    // still decode (nil == no rules, which is the correct default: most users
    // need none). See Quirk #20 for why the global DNS setting cannot do this.
    var resolverRules: [ResolverRule]? = nil


    /// The UA to actually pass to openconnect, or nil to leave it alone.
    var effectiveUserAgent: String? {
        let ua = userAgent ?? VPNConfig.defaultUserAgent
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
        copy.openconnectPath = ManagedRuntime.openconnect
        copy.vpncScriptPath = ManagedRuntime.script
        copy.userAgent = userAgent.map { VPNConfig.cleanField($0) }
        copy.resolverRules = resolverRules?.map {
            ResolverRule(domain: VPNConfig.cleanField($0.domain).lowercased(),
                         nameserver: VPNConfig.cleanField($0.nameserver))
        }
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

/// A per-domain DNS override, materialised as `/etc/resolver/<domain>`
/// containing `nameserver <nameserver>`.
///
/// Why this exists rather than a DNS setting: the global DNS setting has
/// exactly one winner. Point it at the intranet nameserver and every public
/// name breaks; point it at a public resolver and intranet-only names break.
/// Worse, the intranet nameserver is typically reachable only through the
/// tunnel, so with the VPN down a global setting kills DNS entirely — the
/// gateway's own hostname included, which makes reconnecting impossible.
/// macOS resolves by longest domain suffix, so one file per domain scopes the
/// intranet nameserver to exactly the names that need it. See Quirk #20.
struct ResolverRule: Codable, Equatable {
    var domain: String
    var nameserver: String
}

extension ResolverRule {
    /// Parse the Settings text box: one `<domain> <nameserver>` pair per line,
    /// `#` starts a comment. Returns the valid rules plus the lines that could
    /// not be understood, so the caller can tell the user instead of silently
    /// dropping a typo.
    static func parseReportingErrors(_ text: String) -> (rules: [ResolverRule], badLines: [String]) {
        var rules: [ResolverRule] = []
        var bad: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine.prefix(while: { $0 != "#" }))
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 2, isValidDomain(parts[0]), isValidIPv4(parts[1]) else {
                bad.append(line)
                continue
            }
            rules.append(ResolverRule(domain: parts[0].lowercased(), nameserver: parts[1]))
        }
        return (rules, bad)
    }

    /// Lenient variant for live typing — an incomplete line is simply not a
    /// rule yet, so the field never fights the user mid-word.
    static func parse(_ text: String) -> [ResolverRule]? {
        let rules = parseReportingErrors(text).rules
        return rules.isEmpty ? nil : rules
    }

    static func format(_ rules: [ResolverRule]) -> String {
        rules.map { "\($0.domain) \($0.nameserver)" }.joined(separator: "\n")
    }

    /// Rules whose domain would ALSO capture the VPN gateway's own hostname.
    ///
    /// macOS matches `/etc/resolver` files by longest domain suffix, so a file
    /// named for a zone captures every name beneath it. If the gateway's own
    /// FQDN sits in that zone, its name starts resolving only via the intranet
    /// nameserver — which is reachable only through the tunnel. With the VPN
    /// down `openconnect` can then never resolve the gateway, so the app can
    /// never reconnect, and the only way out is deleting the file as root.
    ///
    /// This is not hypothetical: it was observed on 2026-09-08 as
    /// `getaddrinfo failed for host '<gateway>'` on eight consecutive connect
    /// attempts, with the dependency check reporting everything green. Callers
    /// MUST refuse to write such a rule.
    static func rulesCapturingGateway(_ rules: [ResolverRule],
                                      gatewayHost: String) -> [ResolverRule] {
        let host = gatewayHost.lowercased()
        guard !host.isEmpty else { return [] }
        return rules.filter { rule in
            let domain = rule.domain.lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Strict on purpose: the domain becomes both a filename and a shell
    /// argument in a command run as root, so anything outside
    /// letters/digits/`-`/`.` is rejected rather than escaped.
    static func isValidDomain(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253,
              !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        // Require at least one dot: a single-label resolver file would capture
        // a whole top-level suffix, which is never what the user means here.
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3
                && part.allSatisfy { $0.isASCII && $0.isNumber }
                && UInt8(part) != nil
        }
    }
}
