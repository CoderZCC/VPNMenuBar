import Foundation

enum ResolverFileError: Error, LocalizedError {
    case wouldCaptureGateway(domains: [String], gatewayHost: String)
    case invalidRule(ResolverRule)
    case nothingToDo

    var errorDescription: String? {
        switch self {
        case .wouldCaptureGateway(let domains, let gatewayHost):
            return """
            Refusing to write \(domains.joined(separator: ", ")) — the VPN gateway \
            \(gatewayHost) is inside that domain.

            macOS resolves by longest domain suffix, so this rule would also send the \
            gateway's own hostname to the intranet nameserver, which is only reachable \
            through the tunnel. With the VPN down the gateway name would stop resolving \
            and this app could never reconnect.

            Use the full hostname you actually need instead of the parent domain.
            """
        case .invalidRule(let rule):
            return "Not a valid rule: \"\(rule.domain) \(rule.nameserver)\"."
        case .nothingToDo:
            return "Every DNS rule is already installed."
        }
    }
}

/// Persistent, scoped DNS rules installed only through system authorization.
enum ResolverFileManager {
    static let directory = "/etc/resolver"

    /// Identifies a file this app owns. Files without it — hand-written ones,
    /// and the `kt.*` files KtConnect writes — are never removed or counted
    /// as ours.
    static let marker = "# Managed by VPNMenuBar"

    static func path(forDomain domain: String) -> String {
        "\(directory)/\(domain)"
    }

    static func content(for rule: ResolverRule) -> String {
        """
        \(marker)
        # Sends only \(rule.domain) to the intranet nameserver; every other name
        # keeps using the system resolver. Remove this file to revoke:
        #   sudo rm \(path(forDomain: rule.domain)) && sudo killall -HUP mDNSResponder
        nameserver \(rule.nameserver)
        """
    }

    /// The `nameserver` currently configured for a domain, or nil when no file
    /// exists. Resolver files are world-readable, so this needs no privileges.
    static func installedNameserver(forDomain domain: String) -> String? {
        guard let text = try? String(contentsOfFile: path(forDomain: domain), encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "nameserver" {
                return String(fields[1])
            }
        }
        return nil
    }

    static func isManaged(domain: String) -> Bool {
        guard let text = try? String(contentsOfFile: path(forDomain: domain), encoding: .utf8)
        else { return false }
        return text.split(separator: "\n").contains(Substring(marker))
    }

    /// Rules that are missing or point at a different nameserver than configured.
    static func pendingRules(_ rules: [ResolverRule]) -> [ResolverRule] {
        rules.filter { installedNameserver(forDomain: $0.domain) != $0.nameserver }
    }

    /// Files we previously wrote whose domain is no longer in the config.
    /// Only marked files are considered, so removing a rule from Settings can
    /// never delete a hand-written or KtConnect resolver file.
    static func orphanedDomains(keeping rules: [ResolverRule],
                                fileManager: FileManager = .default) -> [String] {
        let wanted = Set(rules.map { $0.domain.lowercased() })
        let entries = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
        return entries
            .filter { ResolverRule.isValidDomain($0) && !wanted.contains($0.lowercased()) && isManaged(domain: $0) }
            .sorted()
    }

    /// Write every pending rule and remove our orphans in ONE authorization
    /// prompt, then reload the DNS cache.
    static func install(rules: [ResolverRule],
                        gatewayHost: String,
                        fileManager: FileManager = .default) async throws {
        // Hard guard first — see ResolverRule.rulesCapturingGateway. This is the
        // one mistake the user cannot recover from inside the app.
        let dangerous = ResolverRule.rulesCapturingGateway(rules, gatewayHost: gatewayHost)
        if !dangerous.isEmpty {
            AppLogger.shared.error(
                "ResolverFileManager: refusing rules that capture gateway \(gatewayHost): "
                + dangerous.map { $0.domain }.joined(separator: ", "))
            throw ResolverFileError.wouldCaptureGateway(
                domains: dangerous.map { $0.domain }, gatewayHost: gatewayHost)
        }
        for rule in rules where !(ResolverRule.isValidDomain(rule.domain)
                                  && ResolverRule.isValidIPv4(rule.nameserver)) {
            throw ResolverFileError.invalidRule(rule)
        }

        let pending = pendingRules(rules)
        let orphans = orphanedDomains(keeping: rules, fileManager: fileManager)
        guard !pending.isEmpty || !orphans.isEmpty else { throw ResolverFileError.nothingToDo }

        var actions: [String] = []
        if !pending.isEmpty {
            actions.append("installing "
                + pending.map { "\($0.domain)→\($0.nameserver)" }.joined(separator: " "))
        }
        if !orphans.isEmpty {
            actions.append("removing " + orphans.joined(separator: " "))
        }
        AppLogger.shared.info("ResolverFileManager: " + actions.joined(separator: ", "))

        let command = try installationCommand(pending: pending, orphans: orphans)
        _ = try await Task.detached(priority: .userInitiated) {
            try PrivilegedCommand.run(command)
        }.value
        AppLogger.shared.info("Scoped DNS rules updated")
    }

    static func installationCommand(pending: [ResolverRule], orphans: [String]) throws -> String {
        for rule in pending where !ResolverRule.isValidDomain(rule.domain) || !ResolverRule.isValidIPv4(rule.nameserver) {
            throw ResolverFileError.invalidRule(rule)
        }
        guard orphans.allSatisfy(ResolverRule.isValidDomain) else {
            throw DependencyInstallError.unsupported(reason: "Invalid managed DNS filename.")
        }
        let q = PrivilegedCommand.quote
        var steps = ["""
        set -eu
        umask 077
        [ ! -L /etc/resolver ] || exit 60
        /bin/mkdir -p -m 755 /etc/resolver
        [ "$(/usr/bin/stat -f %u /etc/resolver)" = 0 ] || exit 61
        mode=$(/usr/bin/stat -f %Lp /etc/resolver)
        [ $((0$mode & 022)) -eq 0 ] || exit 62
        case "$(/bin/ls -lde /etc/resolver | /usr/bin/awk '{print $1}')" in *+*) exit 63;; esac
        """]
        // Preflight every destination before making any changes.
        for domain in Set(pending.map(\.domain) + orphans).sorted() {
            let path = q(path(forDomain: domain))
            steps.append("""
            if [ -e \(path) ] || [ -L \(path) ]; then
                [ ! -L \(path) ] && [ -f \(path) ] || exit 64
                [ "$(/usr/bin/stat -f %u \(path))" = 0 ] || exit 65
                /usr/bin/grep -Fxq \(q(marker)) \(path) || exit 66
            fi
            """)
        }
        for rule in pending {
            steps.append("""
            tmp=$(/usr/bin/mktemp /etc/resolver/.vpnmenubar.XXXXXXXX)
            trap '/bin/rm -f "$tmp"' EXIT
            /usr/bin/printf '%s\\n' \(q(content(for: rule))) > "$tmp"
            /usr/sbin/chown root:wheel "$tmp"
            /bin/chmod 644 "$tmp"
            /bin/mv -f "$tmp" \(q(path(forDomain: rule.domain)))
            trap - EXIT
            """)
        }
        for domain in orphans { steps.append("/bin/rm -f " + q(path(forDomain: domain))) }
        steps.append("/usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true")
        return steps.joined(separator: "\n")
    }
}
