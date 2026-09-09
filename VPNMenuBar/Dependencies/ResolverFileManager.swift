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

/// Installs and inspects `/etc/resolver/<domain>` files.
///
/// The files are persistent, so nothing here runs per connect: one
/// authorization writes them and they stay. That is why this needs no sudoers
/// entry of its own and reuses the same `osascript ... with administrator
/// privileges` path as `DependencyInstaller.installSudoersRule` — the only
/// privilege escalation available under ad-hoc signing (Quirk #13).
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
        return text.contains(marker)
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
            .filter { !wanted.contains($0.lowercased()) && isManaged(domain: $0) }
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

        try await Task.detached(priority: .userInitiated) {
            var steps: [String] = ["/bin/mkdir -p \(directory)"]
            var tmpPaths: [String] = []
            defer { tmpPaths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

            for rule in pending {
                // User-owned temp file; only the `install` step needs root.
                let tmp = NSTemporaryDirectory() + "vpnmenubar-resolver-\(UUID().uuidString)"
                try content(for: rule).write(toFile: tmp, atomically: true, encoding: .utf8)
                tmpPaths.append(tmp)
                steps.append("/usr/bin/install -m 644 -o root -g wheel \"\(tmp)\" \"\(path(forDomain: rule.domain))\"")
            }
            for domain in orphans {
                steps.append("/bin/rm -f \"\(path(forDomain: domain))\"")
            }
            // Never let a failed cache reload fail the whole install — the files
            // are already correct and macOS picks them up on its own shortly.
            let shellCmd = steps.joined(separator: " && ")
                + " && (/usr/bin/killall -HUP mDNSResponder || true)"
            try runPrivileged(shellCmd)
        }.value

        AppLogger.shared.info("ResolverFileManager: install succeeded")
    }

    // MARK: - privileged execution

    /// Mirrors DependencyInstaller's AppleScript path, including the -128
    /// cancel mapping, so a cancelled prompt stays silent in the UI.
    private static func runPrivileged(_ shellCmd: String) throws {
        let escaped = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(
            source: "do shell script \"\(escaped)\" with administrator privileges")
        else {
            throw DependencyInstallError.osascriptFailed(message: "Could not build AppleScript")
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { throw DependencyInstallError.userCancelled }
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            AppLogger.shared.error("ResolverFileManager: osascript failed: \(msg) (code \(code))")
            throw DependencyInstallError.osascriptFailed(message: "\(msg) (code \(code))")
        }
    }
}
