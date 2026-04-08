import Foundation

enum DependencyID: String { case homebrew, openconnect, sudoersRule, vpncScript }

/// A fix action that can be performed inside the app, vs. the existing
/// copyable-command escape hatch (`fixCommand`). When non-nil, the
/// `DependencyRowView` renders a "Fix" button that dispatches into
/// `DependencyInstaller`.
enum InAppFix: Equatable {
    case openTerminalForHomebrew
    case installOpenconnect(brewPath: String)
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
        let brewFix: InAppFix? = homebrewPassed
            ? .installOpenconnect(brewPath: ArchDetector.defaultPaths.brew)
            : nil

        guard fileManager.fileExists(atPath: config.openconnectPath) else {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect not found at \(config.openconnectPath)",
                fixHint: homebrewPassed
                    ? "Click Install via brew to run 'brew install openconnect' inside the app."
                    : "openconnect not found. Install Homebrew first (the row above), then come back and install openconnect.",
                fixCommand: "brew install openconnect",
                inAppFix: brewFix
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
        } else {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect at \(config.openconnectPath) failed to run",
                fixHint: "openconnect exists but --version returned non-zero. Reinstall with 'brew reinstall openconnect'.",
                fixCommand: "brew reinstall openconnect",
                inAppFix: brewFix
            )
        }
    }

    private func checkSudoersRule(config: VPNConfig, openconnectPassed: Bool) -> DependencyStatus {
        // Skip if openconnect itself is missing — no point in double-reporting.
        guard openconnectPassed else {
            return DependencyStatus(
                id: .sudoersRule,
                passed: false,
                detail: "Skipped (openconnect missing)",
                fixHint: "Fix the openconnect dependency above first, then recheck.",
                fixCommand: nil,
                inAppFix: nil
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
}
