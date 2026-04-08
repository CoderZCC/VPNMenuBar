# In-App Dependency Installer — Implementation Plan

> **For agentic workers:** This plan should be executed task-by-task. Each task is self-contained: implement → `xcodebuild` (and `xcodegen generate` when adding new files) → manual smoke verify → checkbox done. The codebase has **no automated tests** by design (per `CLAUDE.md`), so verification is by build success + manual smoke. Do NOT add XCTest infrastructure. Do NOT commit unless the user explicitly says so (`推送代码`).

**Goal:** Replace the colleague-must-run-`install-deps.sh` setup flow with one-click in-app fix actions for missing Homebrew, openconnect, sudoers rule (including the new `/sbin/route` entry), and wrong vpnc-script path.

**Architecture:** New `Dependencies/ArchDetector.swift` produces arch-correct default paths; `VPNConfig` defaults consume them. New `Dependencies/DependencyInstaller.swift` is a stateless namespace exposing four fix actions (terminal handoff for brew, in-process `brew install openconnect`, osascript-admin sudoers write, ConfigStore mutation for vpnc path). `DependencyChecker` gains a fourth dep (`homebrew`), tightens the sudoers probe to verify `/sbin/route`, and attaches an `inAppFix: InAppFix?` discriminant to each `DependencyStatus`. `DependencyRowView` renders a Fix button when present; `OnboardingView` and `DependencyAlertView` each own a small dispatcher that drives the installer and refreshes the dep check.

**Tech Stack:** SwiftUI, AppKit (`NSAppleScript`), Foundation `Process`, `osascript ... with administrator privileges` (macOS Authorization Services), Homebrew (host system).

**Spec:** `docs/superpowers/specs/2026-04-07-in-app-dependency-installer-design.md`

---

## File structure

| Path | New / Modified | Responsibility |
|---|---|---|
| `VPNMenuBar/Dependencies/ArchDetector.swift` | NEW | `uname -m` → `(brew, openconnect, vpncScript)` default paths |
| `VPNMenuBar/Dependencies/DependencyInstaller.swift` | NEW | Four imperative fix actions + error enum |
| `VPNMenuBar/Dependencies/DependencyChecker.swift` | MOD | New `homebrew` dep, `InAppFix` enum, `inAppFix` field, `/sbin/route` probe |
| `VPNMenuBar/Config/VPNConfig.swift` | MOD | Default paths come from `ArchDetector` |
| `VPNMenuBar/UI/DependencyRowView.swift` | MOD | Fix button + progress line for in-progress installs |
| `VPNMenuBar/UI/OnboardingView.swift` | MOD | Dispatcher in DependencyCheck step |
| `VPNMenuBar/UI/DependencyAlertView.swift` | MOD | Same dispatcher, takes `configStore` |
| `VPNMenuBar/App/VPNMenuBarApp.swift` | MOD | Pass `configStore` to `DependencyAlertView` |
| `INSTALL.md` | MOD | Demote `install-deps.sh` to fallback; Onboarding becomes primary |
| `CLAUDE.md` | MOD | New Quirk #12 documenting in-app installer |
| `install-deps.sh` | UNCHANGED | Stays as terminal-only fallback |

---

### Task 1: ArchDetector + VPNConfig defaults

**Files:**
- Create: `VPNMenuBar/Dependencies/ArchDetector.swift`
- Modify: `VPNMenuBar/Config/VPNConfig.swift`

- [ ] **Step 1: Create `ArchDetector.swift`**

```swift
import Foundation

enum CPUArchitecture: Equatable {
    case appleSilicon
    case intel
}

struct ArchPaths: Equatable {
    let brew: String
    let openconnect: String
    let vpncScript: String
}

/// Maps the host CPU architecture to the canonical Homebrew install prefix
/// (`/opt/homebrew` on Apple Silicon, `/usr/local` on Intel) and the three
/// dependency paths the app cares about. Used by `VPNConfig` defaults and
/// `DependencyChecker` so Intel users get the right paths without manually
/// editing Settings → Advanced.
enum ArchDetector {
    static var current: CPUArchitecture {
        var info = utsname()
        uname(&info)
        let machine: String = withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: info.machine)
            ) {
                String(cString: $0)
            }
        }
        return machine == "arm64" ? .appleSilicon : .intel
    }

    static var defaultPaths: ArchPaths {
        switch current {
        case .appleSilicon:
            return ArchPaths(
                brew: "/opt/homebrew/bin/brew",
                openconnect: "/opt/homebrew/bin/openconnect",
                vpncScript: "/opt/homebrew/etc/vpnc/vpnc-script"
            )
        case .intel:
            return ArchPaths(
                brew: "/usr/local/bin/brew",
                openconnect: "/usr/local/bin/openconnect",
                vpncScript: "/usr/local/etc/vpnc/vpnc-script"
            )
        }
    }
}
```

- [ ] **Step 2: Update `VPNConfig.swift` defaults**

Edit the `var openconnectPath` and `var vpncScriptPath` lines:

```swift
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
```

(Only the two `Path` lines change; the surrounding declaration is shown for context. Do NOT touch existing `config.json` files on disk — `Codable` decode will respect saved values; defaults only fire when the field is missing.)

- [ ] **Step 3: Run xcodegen to add the new file to the Xcode target**

Run: `xcodegen generate`
Expected: `Loaded project ...` then `Created project at VPNMenuBar.xcodeproj`. No errors.

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Sanity-check the arch detection**

This task introduces no UI changes, so smoke test by adding a temporary `NSLog("ArchDetector: \(ArchDetector.defaultPaths)")` in `VPNMenuBarApp.swift`'s `AppCoordinator.init`, build, run, and confirm the Console output matches your machine's arch (Apple Silicon → `/opt/homebrew/...`). **Remove the NSLog before continuing to Task 2.**

---

### Task 2: DependencyChecker — homebrew dep, InAppFix, sudoers route probe

**Files:**
- Modify (rewrite): `VPNMenuBar/Dependencies/DependencyChecker.swift`

- [ ] **Step 1: Replace the entire file with the new version**

```swift
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
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

The UI files (`DependencyRowView`, `OnboardingView`, `DependencyAlertView`) still reference the old `DependencyStatus` initializer signature and will FAIL to compile **only if you forget to update them**. Since we added a NEW field at the end (`inAppFix: InAppFix?`), and Swift's auto-synthesized memberwise init is the only way to construct `DependencyStatus`, **all call sites must pass the new arg**. Search for `DependencyStatus(` and confirm only `DependencyChecker.swift` constructs them — the UI files only READ them, so they should still build cleanly. If anything else fails, fix the call site.

```sh
grep -rn "DependencyStatus(" VPNMenuBar/ --include="*.swift"
```

Expected: only `VPNMenuBar/Dependencies/DependencyChecker.swift` lines.

---

### Task 3: DependencyInstaller — four fix actions

**Files:**
- Create: `VPNMenuBar/Dependencies/DependencyInstaller.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation
import AppKit

enum DependencyInstallError: Error, LocalizedError {
    case userCancelled
    case shellFailed(stderr: String)
    case osascriptFailed(message: String)
    case unsupported(reason: String)
    case configIO(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Cancelled."
        case .shellFailed(let s):
            return s.isEmpty ? "Shell command failed." : s
        case .osascriptFailed(let m):
            return m
        case .unsupported(let r):
            return r
        case .configIO(let e):
            return "Config I/O failed: \(e.localizedDescription)"
        }
    }
}

/// Stateless namespace exposing the four fix actions surfaced by
/// `InAppFix`. UI views invoke these from a dispatcher tied to a
/// `runningFix` state and an error alert.
enum DependencyInstaller {

    /// Open Terminal.app and pre-type the official Homebrew installer
    /// command. Returns immediately. The user runs the command in
    /// Terminal and comes back to click Recheck.
    static func openTerminalForHomebrew() throws {
        let installerCmd = "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        let escaped = appleScriptEscape(installerCmd)
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        try runAppleScript(source)
    }

    /// Run `brew install openconnect` as the current user via Process.
    /// Streams stdout+stderr lines to the progress callback.
    /// Throws `shellFailed(stderr:)` on non-zero exit.
    static func installOpenconnect(
        brewPath: String,
        progress: @Sendable @escaping (String) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brewPath)
            p.arguments = ["install", "openconnect"]

            // brew needs its own bin dir on PATH so it can find auxiliary tools.
            let brewDir = (brewPath as NSString).deletingLastPathComponent
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(brewDir):/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            p.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice

            // Accumulate stderr for the failure tail; also forward live lines to UI.
            let stderrAccum = StderrAccumulator()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                if let s = String(data: chunk, encoding: .utf8) {
                    for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        progress(String(line))
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                stderrAccum.append(chunk)
                if let s = String(data: chunk, encoding: .utf8) {
                    for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        progress(String(line))
                    }
                }
            }

            try p.run()
            p.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            if p.terminationStatus != 0 {
                let stderrText = stderrAccum.snapshotString()
                let tail = String(stderrText.suffix(400))
                throw DependencyInstallError.shellFailed(
                    stderr: tail.isEmpty ? "brew install exited \(p.terminationStatus)" : tail
                )
            }
        }.value
    }

    /// Write /etc/sudoers.d/vpnmenubar-<user> via osascript admin (one TouchID).
    /// Validates with visudo before installing.
    static func installSudoersRule(
        username: String,
        openconnectPath: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            // 1. Build content
            let content = """
            # Auto-generated by VPNMenuBar at \(Date())
            # Grants \(username) passwordless sudo for openconnect, pkill, and route.
            # Remove this file to revoke: sudo rm /etc/sudoers.d/vpnmenubar-\(username)
            \(username) ALL=(root) NOPASSWD: \(openconnectPath), /usr/bin/pkill -x openconnect, /sbin/route
            """

            // 2. Write to a user-owned temp file
            let tmp = NSTemporaryDirectory() + "vpnmenubar-sudoers-\(UUID().uuidString)"
            try content.write(toFile: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            // 3. Build privileged shell command
            let dest = "/etc/sudoers.d/vpnmenubar-\(username)"
            let shellCmd = "/usr/sbin/visudo -c -f \"\(tmp)\" && /usr/bin/install -m 440 -o root -g wheel \"\(tmp)\" \"\(dest)\""

            // 4. Wrap in AppleScript with admin privileges (one TouchID)
            let asEscaped = appleScriptEscape(shellCmd)
            let source = """
            do shell script "\(asEscaped)" with administrator privileges
            """
            try runAppleScript(source)
        }.value
    }

    /// Reset the vpncScriptPath in saved config to the architecture-correct
    /// default. No privilege escalation needed — just a config write.
    static func resetVpncScriptPath(to newPath: String, store: ConfigStore) throws {
        do {
            guard var config = try store.load() else {
                throw DependencyInstallError.unsupported(
                    reason: "No config to update yet — finish Onboarding first."
                )
            }
            config.vpncScriptPath = newPath
            try store.save(config)
        } catch let e as DependencyInstallError {
            throw e
        } catch {
            throw DependencyInstallError.configIO(underlying: error)
        }
    }

    // MARK: - helpers

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Execute an AppleScript source string. Maps the well-known cancel
    /// code (-128) to `userCancelled`; everything else to `osascriptFailed`.
    private static func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw DependencyInstallError.osascriptFailed(message: "Could not build AppleScript")
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 {
                throw DependencyInstallError.userCancelled
            }
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            throw DependencyInstallError.osascriptFailed(message: "\(msg) (code \(code))")
        }
    }
}

/// Tiny mutex-protected wrapper so the Pipe readabilityHandler thread can
/// append to the stderr accumulator without racing the consumer thread.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshotString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: Run xcodegen**

Run: `xcodegen generate`
Expected: success.

- [ ] **Step 3: Build**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

---

### Task 4: DependencyRowView — Fix button + progress display

**Files:**
- Modify: `VPNMenuBar/UI/DependencyRowView.swift`

- [ ] **Step 1: Replace the entire file**

```swift
import SwiftUI
import AppKit

/// Renders a single dependency status row with a Fix button (when an
/// in-app fix is available) and a copyable fallback command.
/// Shared between OnboardingView (step 2) and DependencyAlertView.
struct DependencyRowView: View {
    let status: DependencyStatus

    /// True while a fix action is running for THIS row. The parent owns
    /// the running state and binds it in to disable the button + show a
    /// spinner. The progress line (most recent stdout/stderr line during
    /// `installOpenconnect`) replaces the detail line while running.
    var running: Bool = false
    var progressLine: String = ""

    /// Invoked when the user clicks the Fix button. Parent owns the
    /// dispatch into `DependencyInstaller`.
    var onFix: ((InAppFix) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(status.passed ? .green : .red)
                Text(running && !progressLine.isEmpty ? progressLine : status.detail)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(running ? 1 : nil)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if running {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !status.passed {
                Text(status.fixHint)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .center, spacing: 8) {
                    if let fix = status.inAppFix, let onFix {
                        Button(fixButtonLabel(for: fix)) {
                            onFix(fix)
                        }
                        .disabled(running)
                    }
                    if let cmd = status.fixCommand {
                        Spacer(minLength: 0)
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)
                        Button("Copy") { copy(cmd) }
                    }
                }
            }
        }
    }

    private func fixButtonLabel(for fix: InAppFix) -> String {
        switch fix {
        case .openTerminalForHomebrew:           return "Open Terminal"
        case .installOpenconnect:                return "Install via brew"
        case .configureSudoers:                  return "Configure sudo permissions"
        case .resetVpncScriptPath:               return "Reset path"
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`

Expected: `** BUILD SUCCEEDED **`. The new params have defaults (`running: Bool = false`, `progressLine: String = ""`, `onFix: ((InAppFix) -> Void)? = nil`), so the existing call sites in `OnboardingView` and `DependencyAlertView` continue to compile unchanged. We'll wire them up in tasks 5 and 6.

---

### Task 5: OnboardingView — Fix dispatcher in DependencyCheck step

**Files:**
- Modify: `VPNMenuBar/UI/OnboardingView.swift`

- [ ] **Step 1: Replace the entire file**

```swift
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore
    var onFinished: () -> Void

    @State private var step: Int = 1
    @State private var dependencyStatuses: [DependencyStatus] = []
    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")

    // Dispatcher state for in-app dependency fixes
    @State private var runningFixID: DependencyID? = nil
    @State private var progressLine: String = ""
    @State private var fixError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step) of 4")
                .font(.caption)
                .foregroundColor(.secondary)

            Group {
                switch step {
                case 1: welcomeStep
                case 2: dependencyStep
                case 3: credentialsStep
                default: doneStep
                }
            }

            Spacer()

            HStack {
                if step > 1 && step < 4 {
                    Button("Back") { step -= 1 }
                }
                Spacer()
                nextButton
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
        .onAppear {
            if let existing = (try? configStore.load()) ?? nil {
                config = existing
            }
        }
        .alert("Fix failed", isPresented: Binding(
            get: { fixError != nil },
            set: { if !$0 { fixError = nil } }
        )) {
            Button("OK", role: .cancel) { fixError = nil }
        } message: {
            Text(fixError ?? "")
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to VPN MenuBar").font(.title2).bold()
            Text("This app connects to your corporate VPN using openconnect and a TOTP code. Before you start, it needs three things:")
            VStack(alignment: .leading, spacing: 6) {
                Label("openconnect installed via Homebrew", systemImage: "checkmark.shield")
                Label("A sudo NOPASSWD rule for openconnect", systemImage: "checkmark.shield")
                Label("Your username, password prefix, and TOTP secret", systemImage: "checkmark.shield")
            }
            .font(.callout)
            Text("Your config is stored locally at ~/Library/Application Support/com.example.vpnmenubar/config.json with 0600 permissions. Nothing is uploaded.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dependencyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dependency Check").font(.title2).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(dependencyStatuses, id: \.id.rawValue) { status in
                        DependencyRowView(
                            status: status,
                            running: runningFixID == status.id,
                            progressLine: runningFixID == status.id ? progressLine : "",
                            onFix: { fix in
                                Task { await dispatchFix(fix, for: status.id) }
                            }
                        )
                    }
                }
            }
            Button("Recheck") {
                dependencyStatuses = controller.checkDependencies()
            }
            .disabled(runningFixID != nil)
        }
        .onAppear {
            dependencyStatuses = controller.checkDependencies()
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials").font(.title2).bold()
            TextField("Username", text: $config.username)
            RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
            RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
            HStack {
                ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
                Spacer()
            }
            Text("These three fields are required. Defaults for gateway, cert pin, and paths are already filled in and can be edited later in Settings → Advanced.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Set").font(.title2).bold()
            Text("Setup complete. Click the shield icon in the menu bar and choose Connect when you're ready.")
            Text("Heads up: the first time you launch this unsigned app, macOS will show \"cannot be opened\". Go to System Settings → Privacy & Security → Open Anyway to allow it.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Next button

    @ViewBuilder
    private var nextButton: some View {
        switch step {
        case 1:
            Button("Next") { step = 2 }
                .keyboardShortcut(.defaultAction)
        case 2:
            let allPassed = dependencyStatuses.allSatisfy { $0.passed }
            Button("Next") { step = 3 }
                .keyboardShortcut(.defaultAction)
                .disabled(!allPassed || dependencyStatuses.isEmpty)
        case 3:
            Button("Save & Continue") { saveAndAdvance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!config.isConfigured)
        default:
            Button("Done") { onFinished() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func saveAndAdvance() {
        do {
            try configStore.save(config)
            step = 4
        } catch {
            NSLog("OnboardingView save failed: \(error)")
        }
    }

    // MARK: - Fix dispatcher

    @MainActor
    private func dispatchFix(_ fix: InAppFix, for id: DependencyID) async {
        guard runningFixID == nil else { return }
        runningFixID = id
        progressLine = ""
        defer {
            runningFixID = nil
            progressLine = ""
            dependencyStatuses = controller.checkDependencies()
        }
        do {
            switch fix {
            case .openTerminalForHomebrew:
                try DependencyInstaller.openTerminalForHomebrew()
            case .installOpenconnect(let brewPath):
                try await DependencyInstaller.installOpenconnect(brewPath: brewPath) { line in
                    Task { @MainActor in
                        self.progressLine = line
                    }
                }
            case .configureSudoers(let user, let path):
                try await DependencyInstaller.installSudoersRule(
                    username: user,
                    openconnectPath: path
                )
            case .resetVpncScriptPath(let newPath):
                try DependencyInstaller.resetVpncScriptPath(to: newPath, store: configStore)
            }
        } catch DependencyInstallError.userCancelled {
            // silent — user cancelled the auth dialog
        } catch let err as DependencyInstallError {
            fixError = err.errorDescription
        } catch {
            fixError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

---

### Task 6: DependencyAlertView — same dispatcher + AppCoordinator wiring

**Files:**
- Modify: `VPNMenuBar/UI/DependencyAlertView.swift`
- Modify: `VPNMenuBar/App/VPNMenuBarApp.swift` (one call site)

- [ ] **Step 1: Replace `DependencyAlertView.swift`**

```swift
import SwiftUI

struct DependencyAlertView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore
    var onClose: () -> Void

    @State private var statuses: [DependencyStatus] = []
    @State private var runningFixID: DependencyID? = nil
    @State private var progressLine: String = ""
    @State private var fixError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                Text("Dependencies").font(.title2).bold()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(statuses, id: \.id.rawValue) { s in
                        DependencyRowView(
                            status: s,
                            running: runningFixID == s.id,
                            progressLine: runningFixID == s.id ? progressLine : "",
                            onFix: { fix in
                                Task { await dispatchFix(fix, for: s.id) }
                            }
                        )
                    }
                }
            }

            Divider()

            HStack {
                Button("Recheck") {
                    statuses = controller.checkDependencies()
                }
                .disabled(runningFixID != nil)
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear {
            statuses = controller.checkDependencies()
        }
        .alert("Fix failed", isPresented: Binding(
            get: { fixError != nil },
            set: { if !$0 { fixError = nil } }
        )) {
            Button("OK", role: .cancel) { fixError = nil }
        } message: {
            Text(fixError ?? "")
        }
    }

    // MARK: - Fix dispatcher (mirrors OnboardingView)

    @MainActor
    private func dispatchFix(_ fix: InAppFix, for id: DependencyID) async {
        guard runningFixID == nil else { return }
        runningFixID = id
        progressLine = ""
        defer {
            runningFixID = nil
            progressLine = ""
            statuses = controller.checkDependencies()
        }
        do {
            switch fix {
            case .openTerminalForHomebrew:
                try DependencyInstaller.openTerminalForHomebrew()
            case .installOpenconnect(let brewPath):
                try await DependencyInstaller.installOpenconnect(brewPath: brewPath) { line in
                    Task { @MainActor in
                        self.progressLine = line
                    }
                }
            case .configureSudoers(let user, let path):
                try await DependencyInstaller.installSudoersRule(
                    username: user,
                    openconnectPath: path
                )
            case .resetVpncScriptPath(let newPath):
                try DependencyInstaller.resetVpncScriptPath(to: newPath, store: configStore)
            }
        } catch DependencyInstallError.userCancelled {
            // silent
        } catch let err as DependencyInstallError {
            fixError = err.errorDescription
        } catch {
            fixError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Update `VPNMenuBarApp.swift` call site**

Edit `openDependencyAlert()` (around line 182):

```swift
let view = DependencyAlertView(
    controller: controller,
    configStore: configStore,
    onClose: { [weak self] in
        self?.dependencyAlertWindow?.close()
        self?.dependencyAlertWindow = nil
    }
)
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

---

### Task 7: Manual smoke tests

**Files:** none (verification only)

This task does NOT modify code. It runs the app and exercises each fix path.

- [ ] **Step 1: Release build**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Release clean build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Launch the built app**

Run:
```sh
APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
open "$APP_SRC"
```

Expected: status bar icon appears, no crash.

- [ ] **Step 3: Smoke test — all-green path**

On the developer machine (which already has brew + openconnect + sudoers + vpnc-script):
1. Click status bar icon → Check Dependencies…
2. Verify all four rows show green (Homebrew / openconnect / sudoersRule / vpncScript)
3. Verify no Fix buttons appear

- [ ] **Step 4: Smoke test — sudoers missing /sbin/route**

This is the **upgrade-path scenario** (the original bug we fixed). Simulate it:
```sh
sudo cp /etc/sudoers.d/vpnmenubar-$(whoami) /tmp/vpnmenubar-sudoers-backup
sudo sh -c "sed 's|, /sbin/route||' /tmp/vpnmenubar-sudoers-backup > /etc/sudoers.d/vpnmenubar-$(whoami)"
sudo visudo -c   # confirm still valid
```

Then in the app: Check Dependencies → confirm sudoersRule row turns red with detail "sudo -n /sbin/route failed (...)" and a "Configure sudo permissions" Fix button.

Click Fix → confirm system TouchID/password dialog appears → authenticate → row should auto-recheck and turn green.

Verify the file was rewritten:
```sh
sudo cat /etc/sudoers.d/vpnmenubar-$(whoami)
```
Expected: includes `/sbin/route` at the end of the NOPASSWD list.

If anything went wrong, restore the backup:
```sh
sudo install -m 440 -o root -g wheel /tmp/vpnmenubar-sudoers-backup /etc/sudoers.d/vpnmenubar-$(whoami)
```

- [ ] **Step 5: Smoke test — TouchID cancel**

Repeat step 4 but click Cancel on the TouchID dialog. Expected: the row stays red, **no error alert appears**, the Fix button becomes clickable again.

- [ ] **Step 6: Smoke test — openconnect reinstall (optional, slow)**

Only if you have time and don't mind a few minutes of brew downloading:
```sh
brew uninstall openconnect
```
Restart app → Check Dependencies → openconnect row red with "Install via brew" → click Fix → row should show spinner + brew output lines → 30–120s → auto-recheck → green.

- [ ] **Step 7: Smoke test — vpncScript path reset**

In Settings → Advanced, change `vpncScriptPath` to a deliberately wrong value (`/tmp/nonexistent-vpnc-script`). Save. Open Check Dependencies → vpncScript row should be red with "Reset path" Fix button. Click Fix → auto-recheck → green; verify Settings → Advanced now shows the architecture-correct default.

If any smoke test fails, do not proceed to Task 8 — diagnose, fix, and re-test.

---

### Task 8: Update INSTALL.md and CLAUDE.md

**Files:**
- Modify: `INSTALL.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Edit `INSTALL.md` "快速安装" section**

Find the section starting with `## 快速安装（推荐)` and replace it with:

```markdown
## 快速安装（推荐）

新版本支持**从 app 内一键安装依赖**,不再需要先跑脚本。

1. 解压 `VPNMenuBar-0.1.0.zip`,把 `VPNMenuBar.app` 拖到 `/Applications`
2. **首次启动**:右键点 .app → 选"打开" → 警告框里再次点"打开"(参见下面"手动安装步骤"的第 2 步)
3. 状态栏出现盾牌图标,Onboarding 自动弹出。**Step 2 (Dependency Check)** 会列出三项依赖:
   - **Homebrew** — 没装的话点 **Open Terminal**,会跳到终端打开官方安装脚本,你输一次 macOS 密码,等 5–10 分钟。装完关终端,回 app 点 **Recheck**
   - **openconnect** — 没装的话点 **Install via brew**,app 内自动跑 `brew install openconnect`,30–120 秒
   - **sudo NOPASSWD rule** — 没配的话点 **Configure sudo permissions**,弹 macOS 系统鉴权框 (TouchID 或密码),按一下完成
4. 全绿之后点 Next 进 Step 3 填用户名/密码前缀/TOTP 密钥

**装过 brew + openconnect 的同事升级**:只需要点最后一步的 Configure sudo permissions(为新版的脏路由清理功能补充 `/sbin/route` 这条权限),**1 click + 1 TouchID** 完成。

如果 app 内一键安装走不通(比如 osascript 鉴权一直失败,或者公司 Mac 有 MDM 限制),可以走兜底路径——下面的"手动安装步骤"或者直接跑 `bash install-deps.sh`。
```

- [ ] **Step 2: Demote the script reference**

Find the `bash install-deps.sh` mention and reword to make clear it's a fallback. The existing block:

```markdown
分发包里有一个 `install-deps.sh`,可以一键装好 openconnect + 配置 sudoers 免密规则。在终端 `cd` 到解压后的目录,执行:

```sh
bash install-deps.sh
```
```

becomes:

```markdown
**兜底脚本**:分发包里仍带有 `install-deps.sh`,效果跟 app 内 Onboarding 的 Fix 按钮一致 (装 openconnect + 配 sudoers)。app 内一键不灵的同学可以走这条:

```sh
bash install-deps.sh
```

脚本是幂等的,反复运行不会出问题。
```

- [ ] **Step 3: Edit `CLAUDE.md` — add Quirk #12**

After the existing Quirk #11 block (the stale host route cleanup one), add:

```markdown
12. **In-app dependency installer.** `Dependencies/DependencyInstaller.swift` exposes four fix actions surfaced via `InAppFix` enum entries on `DependencyStatus`. Three of them are non-trivial:
    - **`installOpenconnect(brewPath:progress:)`** spawns `brew install openconnect` as the current user (brew refuses root, so this MUST not be wrapped in osascript admin). PATH is set to `<brewDir>:/usr/bin:/bin:/usr/sbin:/sbin` so brew can find auxiliary tools; `HOMEBREW_NO_AUTO_UPDATE=1` keeps it from doing a 3-minute self-update on every install. stdout+stderr are streamed line-by-line via the `progress` callback to drive the per-row spinner.
    - **`installSudoersRule(username:openconnectPath:)`** writes the sudoers file via `do shell script "..." with administrator privileges` — this is the ONLY supported privilege escalation under our ad-hoc signing constraint (no Developer ID → no SMJobBless). The shell command is `visudo -c -f tmp && install -m 440 -o root -g wheel tmp /etc/sudoers.d/vpnmenubar-<user>`. The temp file is written by the app under `NSTemporaryDirectory()` so it's user-owned; only the `install` step needs root. AppleScript cancel returns `errOSACancel = -128` in the error dictionary — we map that specific code to `DependencyInstallError.userCancelled` and stay silent (the row stays red, the user can click Fix again). All other failures throw `osascriptFailed`.
    - **`openTerminalForHomebrew()`** is the one fix that does NOT install anything itself: it launches Terminal.app via AppleScript with the official Homebrew installer command pre-typed. Homebrew's installer cannot run from inside the app — it needs an interactive `sudo` prompt and explicitly refuses to start as root. The user runs the installer in Terminal, comes back, clicks Recheck.

    `DependencyChecker` reads `ArchDetector.defaultPaths.brew` to decide whether the openconnect / sudoers rows should attach an in-app fix or fall back to the copyable command. The `homebrew` dep is listed FIRST so its `passed` value can be threaded into the `openconnect` check (no point offering "Install via brew" if brew isn't installed).
```

- [ ] **Step 4: Verify both docs render OK**

Run:
```sh
head -40 INSTALL.md
grep -A 2 "Quirk #12\|12\\. \\*\\*In-app" CLAUDE.md
```

Expected: the new sections appear in their files.

---

### Task 9: Build distribution zip

**Files:** none (build artifact only)

- [ ] **Step 1: Clean Release build**

Run:
```sh
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Release clean build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Copy and zip**

Run:
```sh
APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
test -d "$APP_SRC" || { echo "ERROR: Release build not found at $APP_SRC"; exit 1; }
rm -rf ./VPNMenuBar.app ./VPNMenuBar-0.1.0.zip
cp -R "$APP_SRC" ./VPNMenuBar.app
ditto -c -k --keepParent ./VPNMenuBar.app ./VPNMenuBar-0.1.0.zip
ls -lh ./VPNMenuBar-0.1.0.zip
```
Expected: zip file ~600–700 KB.

- [ ] **Step 3: Quick relaunch from the zipped artifact**

```sh
rm -rf /tmp/vpn-smoke && mkdir /tmp/vpn-smoke
ditto -x -k VPNMenuBar-0.1.0.zip /tmp/vpn-smoke
open /tmp/vpn-smoke/VPNMenuBar.app
```
Expected: status bar icon appears, no crash. Click → Check Dependencies → all green. Quit.

---

### Task 10: Stop and report to user

**Files:** none (handoff)

The plan does NOT auto-commit. Per `CLAUDE.md` ("**提交**：当我说'推送代码'时…"), commits happen only on explicit user request.

- [ ] **Step 1: Print the working-tree state**

Run:
```sh
git status --short
```

Expected: shows the new files (`VPNMenuBar/Dependencies/ArchDetector.swift`, `DependencyInstaller.swift`, plan + spec under `docs/superpowers/`) and the modified files (`DependencyChecker.swift`, `VPNConfig.swift`, `DependencyRowView.swift`, `OnboardingView.swift`, `DependencyAlertView.swift`, `VPNMenuBarApp.swift`, `INSTALL.md`, `CLAUDE.md`, plus the unchanged-from-previous-task `OpenConnectProcess.swift` / `install-deps.sh`).

- [ ] **Step 2: Report to user**

Tell the user: implementation done, all manual smoke tests pass, distribution zip rebuilt to `VPNMenuBar-0.1.0.zip`. Ask whether to commit (and how to split: one commit for everything, or separate commits for the two logical units — last task's stale-route fix vs this task's in-app installer).
