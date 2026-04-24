# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS 13+ SwiftUI status-bar app that connects to the `vpn.example.com` Cisco AnyConnect VPN via `openconnect`, generating the TOTP from a user-provided Base32 secret and prepending a fixed password prefix. It replaces the legacy single-file `vpn.py` script (still in the repo as a reference / migration source).

- Target: Universal Binary (arm64 + x86_64), `LSUIElement` agent app, no Dock icon
- Signing: **ad-hoc only** (`CODE_SIGN_IDENTITY: "-"`, sandbox off, hardened runtime off)
- Project generator: **XcodeGen** — `VPNMenuBar.xcodeproj` is regenerated from `project.yml` and is `.gitignore`d
- User-facing strings: English literals throughout, no i18n framework
- Tests: **none** (the `VPNMenuBarTests` target and files were removed; some workaround artifacts remain — see Quirks #4 and #5)
- Public repo: <https://github.com/CoderZCC/VPNMenuBar>. The prebuilt `VPNMenuBar.app/` is committed in-tree so users can `cp -R` it to `/Applications` without building from source

## ⚠️ Placeholder values (post-scrub)

This repo went through a `git filter-repo` desensitization pass before going public. Several values in the source are **placeholders**, NOT real defaults that should ever be left untouched by an end user:

| Field | Placeholder in source | Where |
|---|---|---|
| `gateway` | `""` (empty) | `VPNConfig.swift` — required field, user must fill in onboarding or Settings |
| `serverCertPin` | `""` (empty) | `VPNConfig.swift` — required field, user must fill in onboarding or Settings |
| `passwordPrefix` examples | `ExamplePass2021` | `vpn.py`, design docs |
| `username` examples | `first.last` | docs only |
| `totpSecret` examples | `EXAMPLEBASE32SECRETPLACEHOLDER34` | `vpn.py`, design docs (32-char Base32, syntactically valid but obviously not a real secret) |
| Bundle ID | `com.example.vpnmenubar` | `project.yml`, `ConfigStore.swift`, `VPNController.swift`, `NetworkMonitoring.swift`, Info.plist |

**Critical invariant**: when assisting a real user with their own VPN config, **never commit their real values back to this repo**. The user fills their own gateway / cert pin / password prefix / TOTP secret into `~/Library/Application Support/com.example.vpnmenubar/config.json` (which is outside the repo and 0600). If the user pastes their real values into a chat, treat them as secrets — help them put the values into Settings UI / config file, but do not echo them back into source files, design docs, or test fixtures.

## Repo-local git identity

`git config --local user.name` is set to `demo` and `user.email` to `demo@example.com` for this repo specifically (not global). This is intentional — it prevents the original author's real name/email from leaking into commit metadata when pushing to the public GitHub. **Don't change it.** Any commit you make will be authored as `demo <demo@example.com>`, which is correct.

## Build, run, ship

**Regenerate the Xcode project** — required whenever you **add or remove** a source file:
```sh
xcodegen generate
```
The `sources:` entry in `project.yml` is a recursive glob, but it's resolved at `xcodegen generate` time and baked into `VPNMenuBar.xcodeproj`. Editing the contents of an existing file does not require regeneration; **adding a new `.swift` file does**, otherwise `xcodebuild` will silently leave it out of the target and any other file referencing it fails with `Cannot find type X in scope` at link time. (`VPNMenuBar.xcodeproj` is `.gitignore`d so colleagues regenerate from `project.yml` on first build anyway.)

**Debug build** (what you launch during development):
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```

**Release build + distribution zip** (what goes to colleagues):
```sh
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Release clean build

# Copy out of DerivedData and zip with ditto (preserves xattrs):
APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
cp -R "$APP_SRC" ./VPNMenuBar.app
ditto -c -k --keepParent ./VPNMenuBar.app ./VPNMenuBar-X.Y.Z.zip
```

**Signing for Sparkle** (after creating the zip):
```sh
# sign_update lives in the Sparkle SPM artifact:
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData/VPNMenuBar-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name sign_update -maxdepth 1)"
"$SIGN_UPDATE" ./VPNMenuBar-X.Y.Z.zip
# Copy the edSignature and length into appcast.xml's new <item>
```

**Launch the built app for manual smoke testing**:
```sh
open ./VPNMenuBar.app       # first run will hit Gatekeeper — right-click → Open
```

There are no lint/test commands — the test target was removed on purpose. IDE diagnostics from SourceKit (e.g. "Cannot find type `VPNController` in scope" in single-file view) are noise because SourceKit can't see the Xcode target's module context; trust `xcodebuild` output.

## Architecture

Single-target SwiftUI app. Strict one-way dependency graph:

```
 UI  →  Core  →  Config / Dependencies
  \
   → Util
```

- **Config/** — `VPNConfig` Codable struct + `ConfigStore` (atomic 0600 JSON writes at `~/Library/Application Support/com.example.vpnmenubar/config.json`, broken-file backup on decode error)
- **Core/** — pure/stateful logic. Key types:
  - `VPNState` — 4-case enum (`disconnected`, `connecting`, `connected(since:)`, `failed(reason:)`) with `isSetupIncomplete` helper
  - `TOTPGenerator` — RFC 6238 HMAC-SHA1 via `CryptoKit`; own Base32 decoder
  - `QRCodeSecretExtractor` — decodes `otpauth://totp/...` URIs from a CIImage via `CIDetector`, returns the Base32 secret + optional account name (used by the import-from-image button in Onboarding/Settings)
  - `ProcessRunning` protocol + `SystemProcessRunner` — one-shot subprocess wrapper (used for `pgrep`, `sudo -n pkill`, etc.)
  - `OpenConnectProcessRunning` protocol + `OpenConnectProcess` — long-running `sudo openconnect` wrapper. Owns a `Process`, drains stderr via `readabilityHandler`, runs `waitForHandshake(timeout:)` as the "did we actually connect?" judge
  - `NetworkMonitoring` protocol + `NetworkMonitor` — wraps `NWPathMonitor`
  - **`VPNController`** — the `@MainActor ObservableObject` state machine. All UI binds to its `@Published state`. Owns `shouldAutoReconnect` intent flag, handles auto-disconnect/reconnect on network changes
- **Dependencies/**
  - `ArchDetector.swift` — maps `uname.machine` to `appleSilicon`/`intel` and exposes `defaultPaths` (brew, openconnect, vpnc-script). Used by both `VPNConfig` defaults and `DependencyChecker` so Intel users get `/usr/local/...` automatically without editing Settings
  - `DependencyChecker.swift` — verifies homebrew is installed, openconnect is installed, sudoers NOPASSWD works for both `sudo -n openconnect --version` and `sudo -n /sbin/route -n get default`, and vpnc-script exists. Returns `[DependencyStatus]` with copyable fix hints AND optional `InAppFix` enum cases that drive the Fix buttons
  - `DependencyInstaller.swift` — stateless namespace exposing the four in-app fix actions: `openTerminalForHomebrew`, `installOpenconnect(brewPath:progress:)`, `installSudoersRule(username:openconnectPath:)`, `resetVpncScriptPath(to:store:)`. See Quirk #13 for why each one uses the privilege model it uses
- **UI/** — SwiftUI views: `MenuContentView`, `SettingsView`, `OnboardingView`, `DependencyAlertView`, `DependencyRowView`, `AboutView`, `StatusBarIconFactory` (white rounded-rect badge with cutout shield + colored status dot), `RevealableSecureField` (eye-toggle SecureField for password/TOTP fields), `ImportSecretFromImageButton` (file-picker → `QRCodeSecretExtractor`)
- **Util/LoginItemManager.swift** — thin `SMAppService.mainApp` wrapper. Preference is stored in **UserDefaults** (key `launchAtLoginEnabled`), not in `VPNConfig`, to avoid Codable schema migration
- **App/VPNMenuBarApp.swift** — `@main` + `AppCoordinator` (owns the singleton controller, hosts Onboarding/Settings/DependencyAlert/About as plain `NSWindow`s, initializes `SPUStandardUpdaterController` for Sparkle auto-updates) + `AppDelegate` (intercepts `applicationShouldTerminate` to disconnect VPN on every quit path including Cmd-Q)

### VPNController state machine — the "how does VPN actually work" knob

Reading this + `OpenConnectProcess.swift` is the shortest path to understanding the whole app.

- `connect()` guards on config completeness → runs `dependencyChecker.check()` off-main (via `Task.detached` — the sync probes block for seconds and must not freeze the main thread) → generates TOTP → spawns `sudo openconnect ... --passwd-on-stdin` → awaits `waitForHandshake(timeout: 5)` (which polls stderr for success keywords AND `pgrep`-confirms the child is alive). Success sets `shouldAutoReconnect = true`; failure does not.
- `disconnect()` clears `shouldAutoReconnect` (user intent = don't reconnect).
- `autoDisconnect()` (private, called by network-loss handler) **preserves** `shouldAutoReconnect` so recovery can retry.
- `startMonitoring()` — post-connect watchdog Task, polls `isRunning()` every 2s; if the child disappears it transitions to `.disconnected` and posts a `UNUserNotification`.
- `handleNetworkChange(reachable:)` — unreachable + `.connected` → `autoDisconnect()`; reachable + `.disconnected` + `shouldAutoReconnect` → `connect()`.
- Auto-reconnect **is deliberately not** triggered on first connect failures (wrong creds, missing deps) — the flag only flips on successful handshake, so we don't spin-loop retry on bad config.

### sudoers requirement and why the dep check is loose

Users must add to `/etc/sudoers.d/vpnmenubar-<user>`:
```
<user> ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -x openconnect, /sbin/route
```

The third entry (`/sbin/route`, no argv constraint) is used by `OpenConnectProcess.cleanupStaleHostRoute(forGateway:)` to delete a stale host route to the VPN gateway before each connect attempt — see Quirk #12. We don't constrain the argv to `route delete <ip>` because (a) the IP is not known until DNS resolves at runtime, and (b) sudoers wildcard matching for IP arguments is fragile. `route` is not a privileged tool beyond what openconnect itself already does to the routing table, so widening the entry is acceptable.

`DependencyChecker` only verifies the `openconnect` entry (via `sudo -n <path> --version`). It **does not** independently verify the `pkill` or `route` entries because sudoers matches argv exactly — any probe other than the exact `pkill -x openconnect` invocation wouldn't match the rule, and we can't probe with the real argv without actually killing any running openconnect. The `route` entry has no such constraint, but we still don't verify it: if it's missing, `cleanupStaleHostRoute` silently no-ops via `try?` and openconnect surfaces its native "Network is unreachable" error. The fix is to re-run `install-deps.sh` (the script's idempotency check now probes `sudo -n /sbin/route -n get default` and rewrites the sudoers file if missing, so old installs auto-upgrade).

## Quirks & non-obvious invariants

Things that require reading multiple files to understand — documenting once here.

1. **`ConfigStore.load()` returns `VPNConfig?`** (nil for missing file), and many callers write `(try? configStore.load()) ?? nil` to flatten the resulting double-optional (`T??` → `T?`). Keep this pattern — the plain `try? ...` form silently breaks when `load()` itself returns nil vs throws.

2. **`vpncScriptPath` default is `/opt/homebrew/etc/vpnc/vpnc-script`**, not the versioned `/opt/homebrew/Cellar/openconnect/<version>/.bottle/etc/vpnc/vpnc-script`. Homebrew's stable symlink survives `brew upgrade openconnect` (which would otherwise break the app on every version bump).

3. **`AppDelegate.applicationShouldTerminate`** intercepts every quit path. It reaches the coordinator via `AppCoordinator.shared` (a `static weak var` set in `init`) — the `@StateObject` from SwiftUI isn't accessible to the NSApplicationDelegate. The Quit menu item in `MenuContentView` just calls `NSApp.terminate(nil)`; the delegate owns all disconnect logic.

4. **`AppCoordinator.init` has a dead XCTest guard** (`if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }`). It was needed when tests existed, because the test host loaded the app's `@main` and synchronous NSWindow creation during `@StateObject` init triggered a SwiftUI precondition abort. Tests are gone now; the guard is harmless dead code. Same applies to `VPNController.startNetworkMonitoring()` being a separate method instead of inlined into `init` — the split was a test-isolation workaround.

5. **`DependencyChecker` is `class`, not `final class`.** Legacy from when a `StubDependencyChecker: DependencyChecker` subclass existed in the test file. Tests are gone; this can safely become `final class`, but nothing actively requires it.

6. **`LoginItemManager.isEnabledPreference`** returns `true` on first launch (when the UserDefaults key is absent). This implements "default-on launch-at-login" without requiring a `VPNConfig` schema change. `AppCoordinator` calls `LoginItemManager.applyPreference()` once at launch to sync the stored preference to `SMAppService.mainApp`.

7. **`SMAppService.mainApp.register()` is location-sensitive** — an app bundle running from `~/Desktop/...` or DerivedData may fail with LaunchServices errors when trying to register as a login item. Production installs should be in `/Applications`. Failures are `NSLog`'d but non-fatal.

8. **App Sandbox is off** (required to spawn `sudo` subprocesses). This means the app can't ship via App Store and is ad-hoc signed only. See `project.yml`'s `ENABLE_APP_SANDBOX: NO` + `CODE_SIGN_IDENTITY: "-"`.

9. **`VPNConfig.isConfigured` checks all five required fields**: `username`, `passwordPrefix`, `totpSecret`, `gateway`, and `serverCertPin` must all be non-empty. Gateway and cert pin default to empty strings and are collected in onboarding step 3 alongside credentials. `SettingsView` tracks an `originalConfig` snapshot — the Save button is disabled until the user actually changes something. On save, the Settings window closes and the app auto-triggers a reconnect (disconnect first if already connected).

10. **Setup-incomplete menu lock-down**. (Note: Quirk #9's `isConfigured` guard runs first — if required fields are empty, you can't even get past Onboarding.) When Onboarding is dismissed without completing, `VPNController.markSetupIncomplete()` sets `state = .failed(reason: "Setup incomplete...")`. `MenuContentView` detects this via `VPNState.isSetupIncomplete` (prefix match on the reason string) and hides Connect/Disconnect/Reconnect/Open Settings — only Status + Check Dependencies + Quit remain. This is fragile-by-design: the prefix match is the contract, don't reword the reason string without updating `isSetupIncomplete`.

11. **`vpnc-script--no-dns` is a bundled resource**, not loaded from disk. It lives at `VPNMenuBar/Resources/vpnc-script--no-dns` and `project.yml` lists it as a single-file `buildPhase: resources` entry (a `type: folder` reference created a nested `Contents/Resources/Resources/` path that `Bundle.main.path(forResource:)` couldn't find). When `config.skipDNSModification == true`, `OpenConnectProcess.start` swaps the `--script` path from `config.vpncScriptPath` to the bundled copy via `Bundle.main.path(forResource:ofType:)`.

12. **Stale host route cleanup before connect.** `vpnc-script` adds a host route to the VPN gateway (so encrypted tunnel traffic doesn't loop into itself) and removes it on disconnect. If openconnect dies *without* running the disconnect phase — SIGKILL, network drop, app crash, sleep/wake — the host route survives, pinned to the previous network's gateway. After switching WiFi the previous gateway is unreachable, so packets to the VPN host hit "Network is unreachable" before they ever leave the box. `OpenConnectProcess.cleanupStaleHostRoute(forGateway:)` runs before every connect: it parses `route -n get default` and `route -n get <gateway>`, and if the host route's nexthop differs from the current default gateway, runs `sudo -n /sbin/route -n delete <ip>`. The "differs from default" guard is important — when the route is fresh/correct it falls through to the default gateway and we must NOT touch it (deleting the live route during reconnect breaks healthy connections). Cleanup is best-effort: failures are `NSLog`'d only and openconnect proceeds.

13. **In-app dependency installer.** `Dependencies/DependencyInstaller.swift` exposes four fix actions surfaced via `InAppFix` enum cases on `DependencyStatus`. Three of them are non-trivial:
    - **`installOpenconnect(brewPath:progress:)`** spawns `brew install openconnect` as the current user (brew refuses root, so this MUST not be wrapped in osascript admin). PATH is set to `<brewDir>:/usr/bin:/bin:/usr/sbin:/sbin` so brew can find auxiliary tools; `HOMEBREW_NO_AUTO_UPDATE=1` keeps it from doing a 3-minute self-update on every install. stdout+stderr are streamed line-by-line via the `progress` callback to drive the per-row spinner.
    - **`installSudoersRule(username:openconnectPath:)`** writes the sudoers file via `do shell script "..." with administrator privileges` — this is the ONLY supported privilege escalation under our ad-hoc signing constraint (no Developer ID → no SMJobBless). The shell command is `visudo -c -f tmp && install -m 440 -o root -g wheel tmp /etc/sudoers.d/vpnmenubar-<user>`. The temp file is written by the app under `NSTemporaryDirectory()` so it's user-owned; only the `install` step needs root. AppleScript cancel returns `errOSACancel = -128` in the error dictionary — we map that specific code to `DependencyInstallError.userCancelled` and stay silent (the row stays red, the user can click Fix again). All other failures throw `osascriptFailed`.
    - **`openTerminalForHomebrew()`** is the one fix that does NOT install anything itself: it launches Terminal.app via AppleScript with the official Homebrew installer command pre-typed. Homebrew's installer cannot run from inside the app — it needs an interactive `sudo` prompt and explicitly refuses to start as root. The user runs the installer in Terminal, comes back, clicks Recheck.

    `DependencyChecker` reads `ArchDetector.defaultPaths.brew` to decide whether the openconnect / sudoers rows should attach an in-app fix or fall back to the copyable command. The `homebrew` dep is listed FIRST so its `passed` value can be threaded into the `openconnect` check (no point offering "Install via brew" if brew isn't installed). `ArchDetector.swift` is also where the arch-aware default paths in `VPNConfig` come from — Intel users now get `/usr/local/...` defaults at first launch instead of having to manually rewrite Settings → Advanced.

    The `install-deps.sh` script remains in the repo as a terminal-only fallback for users whose machines block osascript admin (rare; happens on heavily MDM-managed corporate Macs).

## Distribution

The repo IS the distribution. Three artifacts work together:

1. **`VPNMenuBar.app/`** — committed in-tree as a Release build (ad-hoc signed, Universal). Users do `git clone` then `cp -R VPNMenuBar/VPNMenuBar.app /Applications/`. **Whenever you change any source file, you must rebuild this in-tree `.app` and commit it alongside the source change**, otherwise users who only `git pull` and copy will run a stale binary. The rebuild recipe is in "Build, run, ship" above (Release clean build → `cp -R "$APP_SRC" ./VPNMenuBar.app`)
2. **`INSTALL.md`** — Chinese walkthrough: Gatekeeper bypass, in-app dependency installer (primary path), TOTP secret extraction (zbar / iPhone camera / 1Password / Bitwarden — Google & MS Authenticator do NOT show the secret), uninstall, FAQ. Also documents the `Settings → Advanced` placeholders the user must fill with their own VPN values (gateway, cert pin, password prefix)
3. **`install-deps.sh`** — fallback for users whose Macs block in-app `osascript` admin (heavily-MDM-managed corporate Macs). Idempotent one-shot:
   - Auto-installs Homebrew if missing (via `NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL .../install.sh)"`)
   - Falls back to `$BREW_PREFIX/bin/brew` + `eval "$(brew shellenv)"` when brew exists on disk but isn't on the current shell's PATH
   - `brew install openconnect` (skipped if already installed)
   - Writes `/etc/sudoers.d/vpnmenubar-<user>` with a `visudo -c -f` pre-check. Uses `/etc/sudoers.d/` (not the main `/etc/sudoers`) so uninstall is `sudo rm` of one file and a broken rule can never lock the user out of sudo
   - Handles Intel vs Apple Silicon path differences automatically
4. **`appcast.xml`** — Sparkle appcast feed at repo root. Each release adds a new `<item>` with the version, EdDSA signature, file size, and GitHub Release download URL. Sparkle checks this file periodically to discover updates. Updated manually as part of the release workflow.

Gatekeeper bypass is `xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app` or right-click → Open. Document this in any user-facing instructions.

**Release workflow** (full checklist for cutting a new version):
1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `project.yml`
2. `xcodegen generate` → Release clean build → `cp -R "$APP_SRC" ./VPNMenuBar.app`
3. `ditto -c -k --keepParent ./VPNMenuBar.app ./VPNMenuBar-X.Y.Z.zip`
4. Sign the zip with `sign_update` (see above) → get `edSignature` and `length`
5. Add a new `<item>` to `appcast.xml` with version, signature, length, and GitHub Release download URL
6. Commit all changes (source + in-tree `.app` + zip + appcast.xml)
7. `git push origin main`
8. `gh release create vX.Y.Z ./VPNMenuBar-X.Y.Z.zip --title "vX.Y.Z" --notes "..."` to create the GitHub Release and upload the zip

**Version bumps:** if you change `CFBundleShortVersionString` in `project.yml`, no separate zip rename is needed for the in-tree `.app` — but the release zip should be named `VPNMenuBar-X.Y.Z.zip` to match the `appcast.xml` download URL.

`README.md` is the English entry point for the public repo and links to `INSTALL.md` for the detailed Chinese walkthrough. Both should be kept in sync with feature changes.

## Legacy files (don't touch unless you mean to)

- **`vpn.py`** — the original Python one-shot that the Swift app replaced. Kept as reference documentation for the hardcoded defaults (`vpn.example.com`, cert pin, brew paths). Not executed at runtime.
- **`vpnc-script--no-dns`** (at repo root) — upstream vpnc connect/disconnect script. A copy is bundled into `VPNMenuBar/Resources/` for runtime use; the root copy is kept as the canonical source for any future edits.

## Design docs

The full spec and implementation plan live at:
- `docs/superpowers/specs/2026-04-06-macos-vpn-menubar-app-design.md` — original design decisions (state machine, dependency injection, error taxonomy, spec §§)
- `docs/superpowers/plans/2026-04-06-macos-vpn-menubar-app.md` — original task breakdown (mostly historical at this point)

Both predate several divergent decisions documented in "Quirks" above — when in doubt, the code is the source of truth.
