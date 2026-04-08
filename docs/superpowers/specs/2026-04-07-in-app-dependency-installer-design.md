# In-App Dependency Installer — Design

**Date:** 2026-04-07
**Status:** Draft (awaiting user review)

## Background and motivation

Today, distributing VPNMenuBar to a colleague requires:

1. Unzipping `VPNMenuBar-0.1.0.zip`
2. Running `bash install-deps.sh` in a terminal — installs Homebrew if missing, installs `openconnect`, writes `/etc/sudoers.d/vpnmenubar-<user>`
3. Dragging `VPNMenuBar.app` to `/Applications`, right-click → Open to bypass Gatekeeper
4. Walking through the in-app Onboarding to enter username / password prefix / TOTP secret

Steps 2 and 3 are easy to forget or do in the wrong order, and step 2 is especially fragile when the colleague is upgrading from a previous version: the existing sudoers file may pass the old in-app dependency check (which only probes `openconnect`) but be missing the newly required `/sbin/route` entry. Symptom: VPN can't connect after switching WiFi, with no in-app indication that the sudoers file is the cause.

The user request is **"简化使用流程，争取都在 app 一键配置"** — strive to make the entire setup happen inside the app with as close to one click as is feasible.

## Constraints

- **Ad-hoc code signing only.** No Developer ID, no entitlements for SMJobBless, no privileged helper tools. The only privilege escalation mechanism available is `osascript ... with administrator privileges`, which uses macOS's standard authorization framework (TouchID or password dialog).
- **App is sandboxed-off** so it can spawn arbitrary subprocesses (this is already the case to support `sudo openconnect`).
- **Homebrew installer cannot run from inside the app.** It uses `sudo` interactively (no tty in NSTask), and it explicitly refuses to start when invoked as root, so dropping privileges via osascript admin doesn't help. Brew installation must be delegated to a user-driven Terminal session.
- **`brew install <formula>` itself must run as the regular user**, not root, by Homebrew design. This is fine — we can run it from Process as the app's own user.
- **No XCTest infrastructure** in this project. Verification is by manual smoke test on real machines (Apple Silicon and Intel).

## Goals (success criteria)

1. **Old colleague upgrade path** (already has brew + openconnect, just needs sudoers update): **1 click + 1 TouchID** inside the app, no terminal.
2. **Fresh-Mac path** (nothing installed): one Terminal handoff for Homebrew install + 2 in-app fixes (openconnect, sudoers) + 1 TouchID.
3. **Intel Mac users** auto-detect their architecture and get the right default paths without ever opening Settings → Advanced.
4. **All in-app fix actions are recoverable** — failures show a clear error and a copy-pastable fallback command. The standalone `install-deps.sh` script remains as ultimate fallback.
5. **No regression** for the existing `disconnect on network change` / `auto-reconnect` / stale-host-route cleanup behaviors.

## Non-goals

- Automating the **Homebrew installer itself**. This is technically infeasible inside the app under our constraints (see Constraints above) and the user has explicitly accepted the Terminal handoff for this single step.
- Replacing or removing `install-deps.sh`. It stays in the repo and in the distribution zip as a terminal-only fallback.
- Adding a privileged helper, XPC service, or any architecture that requires Developer ID signing.
- Localizing the new UI strings (codebase convention is English literals only).
- Adding automated tests (codebase has none; verification is manual).

## High-level architecture

Three new pieces sit alongside the existing `Dependencies/` and UI layers:

```
Dependencies/
├── DependencyChecker.swift          [modified]
├── DependencyInstaller.swift        [new]   - imperative fix actions
└── ArchDetector.swift               [new]   - arch → default path triple

Config/
└── VPNConfig.swift                  [modified] - default paths come from ArchDetector

UI/
├── DependencyRowView.swift          [modified] - new Fix button
├── OnboardingView.swift             [modified] - routes onFix
└── DependencyAlertView.swift        [modified] - routes onFix
```

`DependencyInstaller` is a stateless utility namespace exposing three async / throwing functions, one per fix action. UI views invoke them through a closure injected into `DependencyRowView`. The data carrier between checker and UI is an enriched `DependencyStatus` struct that now carries an `inAppFix: InAppFix?` enum describing which (if any) fix action applies to that row.

## Component details

### `ArchDetector`

Tiny pure-data utility. No I/O at runtime beyond reading `uname -m` once via `utsname()`.

```swift
enum CPUArchitecture { case appleSilicon, intel }

struct ArchPaths: Equatable {
    let brew: String           // /opt/homebrew/bin/brew     |  /usr/local/bin/brew
    let openconnect: String    // /opt/homebrew/bin/openconnect | /usr/local/bin/openconnect
    let vpncScript: String     // /opt/homebrew/etc/vpnc/vpnc-script | /usr/local/etc/vpnc/vpnc-script
}

enum ArchDetector {
    static var current: CPUArchitecture { /* uname */ }
    static var defaultPaths: ArchPaths { /* switch on current */ }
}
```

`VPNConfig`'s default initializer uses `ArchDetector.defaultPaths` for `openconnectPath` and `vpncScriptPath` instead of the hardcoded `/opt/homebrew/...` literals.

**Migration concern:** existing `config.json` files on Apple Silicon machines already have `/opt/homebrew/...` saved — these are unaffected because `Codable` decoding only fills in defaults for missing keys. Intel users who previously had to manually edit Settings → Advanced will continue to use whatever they typed. The benefit is for **new installs and new colleagues** — first-launch defaults now match their architecture automatically.

### `DependencyChecker` changes

Add a new dependency ID and field, and tighten the sudoers probe.

```swift
enum DependencyID: String {
    case homebrew      // NEW
    case openconnect
    case sudoersRule
    case vpncScript
}

struct DependencyStatus: Equatable {
    let id: DependencyID
    let passed: Bool
    let detail: String
    let fixHint: String
    let fixCommand: String?
    let inAppFix: InAppFix?    // NEW
}
```

`InAppFix` enum carries everything the installer needs:

```swift
enum InAppFix: Equatable {
    case openTerminalForHomebrew
    case installOpenconnect(brewPath: String)
    case configureSudoers(username: String, openconnectPath: String)
    case resetVpncScriptPath(to: String)
}
```

**Check order and skip semantics** mirror the existing pattern (don't double-report when an upstream dep is broken):

1. `homebrew` — `fileExists(atPath:)` at `ArchDetector.defaultPaths.brew`. If missing, the next three return early as "skipped".
2. `openconnect` — same as today (check path + `--version`), but if it fails AND `homebrew` passed, attach `inAppFix = .installOpenconnect(brewPath:)`.
3. `sudoersRule` — runs **two** `sudo -n` probes:
   - `sudo -n <openconnectPath> --version` (existing)
   - `sudo -n /sbin/route -n get default` (new — verifies the `/sbin/route` entry that the in-app stale-route cleanup needs)
   Both must succeed to mark `passed = true`. If either fails, attach `inAppFix = .configureSudoers(...)`.
4. `vpncScript` — same as today; if the path doesn't exist BUT the architecture-correct path does, attach `inAppFix = .resetVpncScriptPath(to:)` (the user typed a wrong path into Settings → Advanced).

### `DependencyInstaller`

Stateless namespace, no shared state.

```swift
enum DependencyInstallError: Error {
    case userCancelled                    // osascript -128
    case shellFailed(stderr: String)      // generic command failure
    case osascriptFailed(message: String) // osascript-level failure
    case unsupported(reason: String)      // shouldn't happen, defensive
}

enum DependencyInstaller {
    static func openTerminalForHomebrew() throws
    static func installOpenconnect(
        brewPath: String,
        progress: @escaping (String) -> Void
    ) async throws
    static func installSudoersRule(
        username: String,
        openconnectPath: String
    ) async throws
    static func resetVpncScriptPath(to newPath: String, store: ConfigStore) throws
}
```

**`openTerminalForHomebrew`**: builds an AppleScript that does `tell application "Terminal" to do script "..."` with the official installer command:
```
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```
Returns immediately. We do not wait for the user to finish — they come back to the app and click Recheck themselves.

**`installOpenconnect`**: spawns `Process(brewPath, ["install", "openconnect"])` with `PATH` env set to `<brewPath dir>:/usr/bin:/bin:/usr/sbin:/sbin` (so brew can find its own auxiliary tools), pipes stdout+stderr through a `readabilityHandler` that splits on newlines and forwards each non-empty line to the `progress` callback. Awaits termination. Throws `shellFailed` on non-zero exit with the tail of stderr.

**`installSudoersRule`**: builds the sudoers content from the template:
```
<user> ALL=(root) NOPASSWD: <openconnect>, /usr/bin/pkill -x openconnect, /sbin/route
```
Writes to `NSTemporaryDirectory()/vpnmenubar-sudoers-<uuid>` (owned by the app's user, mode 0644), then runs an AppleScript:
```applescript
do shell script "/usr/sbin/visudo -c -f /tmp/.../tmp && /usr/bin/install -m 440 -o root -g wheel /tmp/.../tmp /etc/sudoers.d/vpnmenubar-<user> && /bin/rm /tmp/.../tmp" with administrator privileges
```
This triggers exactly one TouchID/password prompt. The AppleScript cancel button (and TouchID cancel) returns `errOSACancel = -128` in the `NSAppleScriptErrorNumber` of the error dictionary returned by `executeAndReturnError(_:)` — we map that specific code to `DependencyInstallError.userCancelled` and stay silent (the row remains red and the user can click Fix again). All other failures throw `osascriptFailed` with the `NSAppleScriptErrorMessage` string.

**`resetVpncScriptPath`**: this is the only fix that doesn't run a system command — it writes the corrected path back to `VPNConfig` via `ConfigStore`. It still lives in the `DependencyInstaller` namespace (so the dispatcher only ever talks to one place) but its implementation is just `var c = try store.load() ?? .empty; c.vpncScriptPath = newPath; try store.save(c)`. The function takes the `ConfigStore` as an injected parameter, consistent with how the rest of the codebase wires its dependencies.

### UI changes

**`DependencyRowView`** gains a `Fix` button placed between the existing `(detail)` text and the `Copy` button. The button:
- Is rendered only when `status.inAppFix != nil` AND `status.passed == false`
- Title text varies by case: `"Open Terminal"` / `"Install via brew"` / `"Configure sudo permissions"` / `"Reset path"`
- Becomes disabled and shows a `ProgressView()` while a fix action is running
- For the `installOpenconnect` case only, the row's detail line is replaced with the most recent line of brew output during the install (truncated to one line)

The view also gains an `onFix: (InAppFix) -> Void` closure injected by the parent. The parent owns the `Task` that drives the installer and calls `checkDependencies()` again when it finishes (on both success and error).

**`OnboardingView`** Step 2 (DependencyCheck) and **`DependencyAlertView`** both consume `DependencyRowView` and need to wire up `onFix`. They share a thin coordinator pattern: each holds a `@State var runningFix: DependencyID?` to enforce single-action-at-a-time, and a closure that performs the dispatch:

```swift
private func dispatch(fix: InAppFix, for id: DependencyID) async {
    guard runningFix == nil else { return }
    runningFix = id
    defer { runningFix = nil; refreshDependencies() }
    do {
        switch fix {
        case .openTerminalForHomebrew:
            try DependencyInstaller.openTerminalForHomebrew()
        case .installOpenconnect(let brewPath):
            try await DependencyInstaller.installOpenconnect(brewPath: brewPath) { line in
                progressLine = line   // bound into the row
            }
        case .configureSudoers(let user, let path):
            try await DependencyInstaller.installSudoersRule(username: user, openconnectPath: path)
        case .resetVpncScriptPath(let newPath):
            try DependencyInstaller.resetVpncScriptPath(to: newPath, store: configStore)
        }
    } catch DependencyInstallError.userCancelled {
        // silent — no alert
    } catch {
        currentError = error    // displayed via SwiftUI .alert
    }
}
```

The Onboarding step's existing `Recheck` button is preserved and is the user's way to re-probe after the Terminal Homebrew install completes.

## Data flow scenarios

### Scenario A — fresh Mac, nothing installed

1. App launches; first run; Onboarding opens.
2. Step 2 dep check shows: Homebrew ✗ / openconnect ✗ (skipped) / sudoers ✗ (skipped) / vpnc ✗.
3. User clicks Fix on Homebrew row → Terminal.app launches with the installer command pre-typed → user presses Enter → enters their macOS password once → 5–10 minutes pass → user closes Terminal.
4. User returns to app, clicks Recheck.
5. Dep check shows: Homebrew ✓ / openconnect ✗ (Fix enabled) / sudoers ✗ / vpnc ✗.
6. User clicks Fix on openconnect → row spinner + brew output → 30–120 s → completes → auto-recheck.
7. Dep check shows: Homebrew ✓ / openconnect ✓ / sudoers ✗ (Fix enabled) / vpnc ✓.
8. User clicks Fix on sudoers → TouchID prompt → user touches → file written → auto-recheck → all green.
9. Continue → Step 3 (credentials) → Done.

**Total user actions:** 1 Terminal command, 2 Fix clicks, 1 TouchID. (Plus the Onboarding credential entry which is unchanged.)

### Scenario B — old colleague upgrade (already has brew + openconnect)

1. User downloads new VPNMenuBar.app, copies to /Applications.
2. Launches app, sees Failed state when trying to connect (no change in launch behavior).
3. Opens menu → Check Dependencies → DependencyAlertView shows: Homebrew ✓ / openconnect ✓ / sudoers ✗ (Fix enabled) / vpnc ✓.
4. Clicks Fix on sudoers → TouchID → done.

**Total user actions:** 1 Fix click + 1 TouchID. This is the exact scenario the user is most concerned about.

### Scenario C — Intel Mac

1. Intel user launches fresh app.
2. `ArchDetector` detects `x86_64`, returns `/usr/local/...` paths.
3. `VPNConfig` defaults are populated with the Intel paths.
4. Dep check probes the Intel paths from the start. **No manual Settings → Advanced trip required.**

## Error handling

| Action | Failure mode | Handling |
|---|---|---|
| `openTerminalForHomebrew` | osascript can't launch Terminal (very rare) | Alert with the original install command, `Copy` button |
| `installOpenconnect` | Network failure / brew formula issue / brew tap broken | Alert with last 200 bytes of brew stderr + `Open Terminal` button that re-runs the same command in Terminal for manual retry |
| `installSudoersRule` | User cancels TouchID | Silent — row stays red, user can click Fix again |
| `installSudoersRule` | `visudo -c` fails | Defensive throw with content dump (should be impossible since content is hardcoded template) |
| `installSudoersRule` | osascript admin write fails (disk full, etc.) | Alert with underlying error + sudoers content + Copy button (so user can paste into `sudo visudo` manually) |
| `resetVpncScriptPath` | `ConfigStore.save` fails | Alert with the I/O error |

**Universal principle:** every in-app fix has a manual fallback path documented in the alert. `install-deps.sh` remains as the ultimate fallback for users whose machines are pathologically broken.

## Files added / modified

```
NEW:
  VPNMenuBar/Dependencies/DependencyInstaller.swift
  VPNMenuBar/Dependencies/ArchDetector.swift

MODIFIED:
  VPNMenuBar/Dependencies/DependencyChecker.swift
  VPNMenuBar/Config/VPNConfig.swift
  VPNMenuBar/UI/DependencyRowView.swift
  VPNMenuBar/UI/OnboardingView.swift
  VPNMenuBar/UI/DependencyAlertView.swift

  INSTALL.md     (Onboarding becomes the primary path; install-deps.sh demoted to fallback)
  CLAUDE.md      (new Quirk #12 documenting the in-app installer + osascript admin)

UNCHANGED:
  install-deps.sh    (kept as terminal fallback; documents the same sudoers line)
  project.yml        (sources: glob is recursive, picks up new files at xcodegen time)
```

`xcodegen generate` is required because two new `.swift` files are added (per the existing project rule).

Estimated code volume: ~400 lines of new Swift + ~150 lines of edits across the modified files.

## Testing strategy

No automated tests (consistent with the rest of the codebase). Manual smoke tests:

| Case | Method |
|---|---|
| Apple Silicon, all-green path | Already-set-up dev machine → confirm rows green, no Fix buttons appear |
| Apple Silicon, sudoers missing /sbin/route | `sudo` edit `/etc/sudoers.d/vpnmenubar-$(whoami)` to remove `/sbin/route`, restart app → click Fix → TouchID → confirm route entry restored |
| Apple Silicon, openconnect uninstalled | `brew uninstall openconnect`, restart app → click Fix → confirm install + auto-recheck |
| Apple Silicon, brew uninstalled | Risky on the dev machine — borrow a clean Mac or VM. Confirm Terminal handoff works |
| Intel Mac | Borrow Intel colleague's machine, run full Onboarding |
| TouchID cancel | Click Fix → cancel TouchID → confirm no alert, row stays red |
| brew install failure | `airport -z` (disable wifi) → click Fix → confirm alert with brew stderr |

## Open questions

None — all design decisions confirmed during brainstorming.

## Out of scope (for follow-ups, not this design)

- Adding a "Repair installation" command in the menu that runs all four checks + offers to fix all failing items in sequence (currently each row is per-action). Could be a future quality-of-life add.
- Bundled brew tap or pre-built openconnect binary to avoid the brew install step entirely. Out of scope — touches signing/distribution policies.
- Sudoers rule lifecycle on uninstall. The `install-deps.sh` already documents `sudo rm /etc/sudoers.d/vpnmenubar-<user>` as the manual revoke step; an in-app uninstaller is out of scope.
