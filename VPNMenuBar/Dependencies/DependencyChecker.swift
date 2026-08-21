import Foundation

enum DependencyID: String { case homebrew, openconnect, sudoersRule, vpncScript }

/// A fix action that can be performed inside the app, vs. the existing
/// copyable-command escape hatch (`fixCommand`). When non-nil, the
/// `DependencyRowView` renders a "Fix" button that dispatches into
/// `DependencyInstaller`.
enum InAppFix: Equatable {
    case openTerminalForHomebrew
    case installOpenconnect(brewPath: String, upgrade: Bool)
    case configureSudoers(username: String, openconnectPath: String)
    case resetVpncScriptPath(to: String)
}

struct DependencyStatus: Equatable {
    let id: DependencyID
    let passed: Bool
    let detail: String
    let fixHint: String
    let fixCommand: String?
    let inAppFix: InAppFix?
    /// True when the probe never ran because a prerequisite dependency failed.
    /// Still `passed == false` (the UI keeps treating it as unmet), but the log
    /// summary renders it as `skip` so it doesn't read as an independent failure.
    let isSkipped: Bool

    init(id: DependencyID,
         passed: Bool,
         detail: String,
         fixHint: String,
         fixCommand: String?,
         inAppFix: InAppFix?,
         isSkipped: Bool = false) {
        self.id = id
        self.passed = passed
        self.detail = detail
        self.fixHint = fixHint
        self.fixCommand = fixCommand
        self.inAppFix = inAppFix
        self.isSkipped = isSkipped
    }
}

class DependencyChecker {
    private let runner: ProcessRunning
    private let username: String
    private let fileManager: FileManager

    init(runner: ProcessRunning = SystemProcessRunner(),
         username: String = NSUserName(),
         fileManager: FileManager = .default) {
        self.runner = runner
        self.username = username
        self.fileManager = fileManager
    }

    func check(config: VPNConfig) -> [DependencyStatus] {
        let homebrew = checkHomebrew()
        let openconnect = checkOpenconnect(config: config, homebrewPassed: homebrew.passed)
        let sudoers = checkSudoersRule(config: config, openconnectPassed: openconnect.passed)
        let vpnc = checkVpncScript(config: config)
        return [homebrew, openconnect, sudoers, vpnc]
    }

    // MARK: - individual checks

    private func checkHomebrew() -> DependencyStatus {
        let brewPath = ArchDetector.defaultPaths.brew
        if fileManager.fileExists(atPath: brewPath) {
            return DependencyStatus(
                id: .homebrew,
                passed: true,
                detail: "Homebrew installed at \(brewPath)",
                fixHint: "",
                fixCommand: nil,
                inAppFix: nil
            )
        }
        return DependencyStatus(
            id: .homebrew,
            passed: false,
            detail: "Homebrew not found at \(brewPath)",
            fixHint: "Homebrew is required to install openconnect. Click Open Terminal to run the official installer; you'll be asked for your macOS password once during the installer.",
            fixCommand: "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
            inAppFix: .openTerminalForHomebrew
        )
    }

    private func checkOpenconnect(config: VPNConfig, homebrewPassed: Bool) -> DependencyStatus {
        func brewFix(upgrade: Bool) -> InAppFix? {
            homebrewPassed
                ? .installOpenconnect(brewPath: ArchDetector.defaultPaths.brew, upgrade: upgrade)
                : nil
        }

        guard fileManager.fileExists(atPath: config.openconnectPath) else {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect not found at \(config.openconnectPath)",
                fixHint: homebrewPassed
                    ? "Click Install via brew to run 'brew install openconnect' inside the app."
                    : "openconnect not found. Install Homebrew first (the row above), then come back and install openconnect.",
                fixCommand: "brew install openconnect",
                inAppFix: brewFix(upgrade: false)
            )
        }

        let result = (try? runner.run(
            executable: config.openconnectPath,
            arguments: ["--version"],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")

        if result.succeeded {
            let version = result.stdout.split(separator: "\n").first.map(String.init) ?? "unknown"
            return DependencyStatus(
                id: .openconnect,
                passed: true,
                detail: "openconnect installed — \(version)",
                fixHint: "",
                fixCommand: nil,
                inAppFix: nil
            )
        } else if let missingLib = Self.missingDynamicLibrary(inStderr: result.stderr) {
            // A Homebrew dependency was upgraded past the ABI this openconnect
            // build links against (e.g. nettle 3 -> 4 renames libhogweed.6 to
            // libhogweed.7), so dyld refuses to start the process at all.
            // `brew reinstall` re-pours the SAME bottle and does not help —
            // only upgrading to a build compiled against the new dependency does.
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect cannot start — missing dynamic library \(missingLib)",
                fixHint:
                    "A Homebrew dependency was upgraded to a version openconnect was not built against, " +
                    "so \(missingLib) no longer exists. Upgrade openconnect to a build that links the new " +
                    "library — 'brew reinstall' will NOT fix this, it re-installs the same broken build.",
                fixCommand: "brew upgrade openconnect",
                inAppFix: brewFix(upgrade: true)
            )
        } else if result.exitCode == -1 && result.stderr == "timeout" {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect at \(config.openconnectPath) did not respond to --version within 3s",
                fixHint: "openconnect exists but hung on --version. Try running it in Terminal to see where it stalls.",
                fixCommand: "\(config.openconnectPath) --version",
                inAppFix: nil
            )
        } else {
            let reason = Self.firstMeaningfulLine(result.stderr)
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: reason.isEmpty
                    ? "openconnect at \(config.openconnectPath) failed to run (exit \(result.exitCode))"
                    : "openconnect at \(config.openconnectPath) failed to run — \(reason)",
                fixHint: "openconnect exists but --version returned non-zero. Reinstall with 'brew reinstall openconnect'.",
                fixCommand: "brew reinstall openconnect",
                inAppFix: brewFix(upgrade: false)
            )
        }
    }

    private func checkSudoersRule(config: VPNConfig, openconnectPassed: Bool) -> DependencyStatus {
        // Skip when openconnect is missing OR cannot start — both probes below
        // invoke it, so they would just re-report the same failure on this row.
        guard openconnectPassed else {
            return DependencyStatus(
                id: .sudoersRule,
                passed: false,
                detail: "Not checked — the openconnect binary above must work first",
                fixHint: "Fix the openconnect dependency above first, then recheck.",
                fixCommand: nil,
                inAppFix: nil,
                isSkipped: true
            )
        }

        // Probe 1: openconnect via sudo -n
        let openconnectProbe = (try? runner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", config.openconnectPath, "--version"],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")

        // Probe 2: /sbin/route via sudo -n. The route entry has no argv constraint
        // in the sudoers line, so any read-only invocation works as a probe;
        // `route -n get default` is safe and returns 0 if a default route exists.
        let routeProbe = (try? runner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/sbin/route", "-n", "get", "default"],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")

        if openconnectProbe.succeeded && routeProbe.succeeded {
            return DependencyStatus(
                id: .sudoersRule,
                passed: true,
                detail: "sudo NOPASSWD rule active for openconnect, pkill, and route",
                fixHint: "",
                fixCommand: nil,
                inAppFix: nil
            )
        }

        let sudoersLine = "\(username) ALL=(root) NOPASSWD: \(config.openconnectPath), /usr/bin/pkill -x openconnect, /sbin/route"
        let detail: String
        if !openconnectProbe.succeeded {
            detail = "sudo -n openconnect failed (NOPASSWD rule missing or incomplete)"
        } else {
            detail = "sudo -n /sbin/route failed (sudoers missing the /sbin/route entry — needed to clear stale routes after WiFi switch)"
        }
        return DependencyStatus(
            id: .sudoersRule,
            passed: false,
            detail: detail,
            fixHint:
                "This app needs to run sudo openconnect, sudo pkill, AND sudo route without a password prompt. " +
                "Click Configure sudo permissions to write the sudoers file via macOS authorization (TouchID or password).",
            fixCommand: sudoersLine,
            inAppFix: .configureSudoers(username: username, openconnectPath: config.openconnectPath)
        )
    }

    private func checkVpncScript(config: VPNConfig) -> DependencyStatus {
        if fileManager.fileExists(atPath: config.vpncScriptPath) {
            return DependencyStatus(
                id: .vpncScript,
                passed: true,
                detail: "vpnc-script found at \(config.vpncScriptPath)",
                fixHint: "",
                fixCommand: nil,
                inAppFix: nil
            )
        }
        // If the configured path is wrong but the architecture-correct path
        // exists on disk, offer a one-click reset.
        let archCorrect = ArchDetector.defaultPaths.vpncScript
        let resetFix: InAppFix? = (archCorrect != config.vpncScriptPath
                                   && fileManager.fileExists(atPath: archCorrect))
            ? .resetVpncScriptPath(to: archCorrect)
            : nil
        return DependencyStatus(
            id: .vpncScript,
            passed: false,
            detail: "vpnc-script not found at \(config.vpncScriptPath)",
            fixHint: resetFix != nil
                ? "vpnc-script is at the architecture-default path \(archCorrect) instead. Click Reset path to fix the config."
                : "vpnc-script is shipped with the openconnect Homebrew formula. It should live at \(archCorrect) after 'brew install openconnect'. Run 'brew reinstall openconnect' if it is missing.",
            fixCommand: nil,
            inAppFix: resetFix
        )
    }

    // MARK: - stderr parsing

    /// Extract the missing library's filename from a dyld load failure.
    /// dyld writes `Library not loaded: /opt/homebrew/opt/nettle/lib/libhogweed.6.dylib`
    /// followed by a `Reason: tried: ...` block. Returns nil for any other stderr.
    static func missingDynamicLibrary(inStderr stderr: String) -> String? {
        let marker = "Library not loaded:"
        for line in stderr.split(separator: "\n") {
            guard let range = line.range(of: marker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            // Report just the filename — the full path is the *expected*
            // location, which no longer exists and only adds noise.
            return (path as NSString).lastPathComponent
        }
        return nil
    }

    /// First non-blank stderr line, truncated so it stays on one row in the UI.
    static func firstMeaningfulLine(_ stderr: String) -> String {
        for line in stderr.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
        }
        return ""
    }
}
