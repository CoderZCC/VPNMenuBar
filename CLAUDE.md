# VPNMenuBar engineering guidance

## Current architecture

SwiftUI menu-bar app targeting macOS 13+. UI → Core → Config / Dependencies → utilities. A deployment target is not proof of old-OS compatibility. The current source is the managed-deployment security revision; old release artifacts and `docs/superpowers` plans describe historical behavior, not current installation instructions.

- `ConfigStore`: schema 3 settings plus an opaque local credential reference. Verify encrypted readback before replacing schema 1 plaintext. Schema 2 requires explicit re-entry; never interpret Keychain references as local records.
- `LocalCredentialStore`: AES-256-GCM with random per-record keys, authenticated UUIDs and private 0600 files in 0700 directories. Keys are local too; do not claim protection from same-user access or device binding.
- `OpenConnectProcess`: system-authorized session supervisor, private FIFO credential input/control/output, scoped child termination. Complete authorization before generating an OTP. Keep the input FIFO open until stop, or buffered credentials can disappear before the root reader attaches.
- `ManagedRuntime`: bundled payload with compiled hashes, private root-owned session snapshots, frozen no-DNS script digest. Do not accept arbitrary executable or script paths.
- `DependencyInstaller`: recognized legacy-rule revocation and managed-path reset only. No network installer, package manager execution or passwordless sudo grants.
- `ResolverFileManager`: validated domain/IP inputs, root-side provenance checks, root-local staging and explicit system authorization. Never overwrite another tool's resolver files.
- `AppLogger`: private local files, three-day daily cleanup, 2 MiB daily limit. Never emit raw VPN output or credentials to files/system logs.
- No Sparkle, personal update feed or automatic login-item opt-in.

## Settings and upgrades

- First launch and Open Settings use the same settings window. No onboarding wizard or separate Connection Check page. Keep Show Logs directly in the main menu; do not restore a submenu containing only one action.
- Empty configuration offers Save & Connect. Input examples belong inside fields, including the native secure fields. Automatic dependency checks remain in the connection path.
- Preserve `~/Library/Application Support/com.example.vpnmenubar` despite the new bundle identifier. Replacing the App must not clear this directory. Schema 1 migrates after encrypted readback; schema 3 reuses existing credentials; schema 2 keeps settings but requires password/TOTP re-entry.
- A usable backup includes the whole configuration directory and `local-credentials`, not just `config.json`. Missing keys or failed migration must not silently replace existing data. Do not launch old binaries against the current credential format.

## Runtime compatibility and review packages

- Current review build: 0.2.25, Apple Silicon only, compiled for macOS 13. Intel is not supported by the current package. Never lower only Info.plist or Mach-O declarations to claim compatibility.
- `scripts/build-compatible-runtime.py` rebuilds pinned sources under `build/runtime-macos13` without system installation. Required build tools include Xcode/CLT, Python, Ninja, pkg-config and GNU Autoconf/Automake/Libtool; XcodeGen generates the app project. Runtime users do not need these tools.
- Keep the gnulib `strchrnul` compatibility overrides and availability diagnostics: configure probes on a newer host can otherwise select APIs absent on macOS 13. Packaging must reject libraries above the requested minimum OS and preserve the existing OpenConnect feature set.
- After changing the source pins or build recipe, use a fresh build cache as appropriate; cached `.done` markers are not independent rebuild evidence. Preserve compiled hash, payload and notice publication as one transaction.
- The 0.2.25 Release build, all 14 Mach-O minimum-version checks, strict ad-hoc signature verification and security regression suite passed on macOS 26. The isolated p11-kit build passed 44 upstream tests. Actual macOS 13/14/15 connection, DNS/routing cleanup and sleep/reconnect acceptance remain pending. Earlier 0.2.24 real connections do not prove the rebuilt runtime works on older systems.
- Review DMGs and their SHA-256 inventory live in `artifacts/it-review/` on `codex/vpn-security-bundled-runtime`. A review-branch artifact is not a GitHub Release or IT approval. Update package notes and download links when replacing a DMG; never include personal settings or credentials.
- Ad-hoc signature integrity checks do not establish Developer ID signing, notarization or managed-device acceptance.

## Connection diagnosis

- Before restarting, inspect the latest dated log in `~/Library/Logs/VPNMenuBar/`, the actual running App path/version and its owned OpenConnect process. Source, installed App and isolated test copies may differ. Do not launch an ambiguous bundle identifier when several builds exist.
- Distinguish dependency validation, administrator authorization, runtime startup and VPN handshake. The handshake timeout is 20 seconds; the authorization prompt can remain pending independently. Do not generate or submit multiple OTPs through competing test connections.
- A Connecting screenshot alone does not prove the backend is stuck. On 2026-10-09, logs showed a child exit followed by successful automatic reconnection while the reported screenshot showed Connecting. Menu refresh was only a hypothesis, not a confirmed UI defect. Compare timestamps and current state; ask to close/reopen the menu if the UI cannot be inspected.
- A handshake-success log and live process do not prove internal-resource reachability. Report these separately. Never dump process arguments or raw VPN traces containing account data while diagnosing.
- Restarting may disconnect the VPN. Prefer normal Quit so teardown runs; never use a global OpenConnect kill. Keep user authorization requirements for app replacement and system changes.

## Build and tests

Run `python3 scripts/build-compatible-runtime.py` on Apple Silicon to build and package the pinned runtime for macOS 13, then regenerate with `xcodegen generate` after adding/removing Swift files. The generated Xcode project is ignored. Local builds use ad-hoc signing in `project.yml` without Keychain entitlements or a profile. The Bundle ID is `io.coderzcc.vpnmenubar`. Developer ID distribution and notarization remain separate deployment requirements.

```sh
bash tests/run-local-credential-tests.sh
bash tests/run-config-tests.sh
bash tests/run-controller-tests.sh
bash tests/run-security-tests.sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -configuration Debug \
  -destination 'platform=macOS' build
```

`CODE_SIGNING_ALLOWED=NO` is allowed only for compilation checks; it is not runtime acceptance. Do not launch or replace an installed App, alter system configuration, push code or publish artifacts without task authorization. Keep real credentials out of code, logs, tests and documentation. Preserve unrelated worktree changes and the existing repository-local Git identity.

See `docs/security-deployment.md` for release gates and `docs/lessons/` for diagnosed constraints.
