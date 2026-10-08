# VPNMenuBar engineering guidance

## Current architecture

macOS 13+ SwiftUI menu-bar app. UI → Core → Config / Dependencies → utilities. The current source is the managed-deployment security revision; old release artifacts and `docs/superpowers` plans describe historical behavior, not current installation instructions.

- `ConfigStore`: schema 3 settings plus an opaque local credential reference. Verify encrypted readback before replacing schema 1 plaintext. Schema 2 requires explicit re-entry; never interpret Keychain references as local records.
- `LocalCredentialStore`: AES-256-GCM with random per-record keys, authenticated UUIDs and private 0600 files in 0700 directories. Keys are local too; do not claim protection from same-user access or device binding.
- `OpenConnectProcess`: system-authorized session supervisor, private FIFO credential input/control/output, scoped child termination. Complete authorization before generating an OTP. Keep the input FIFO open until stop, or buffered credentials can disappear before the root reader attaches.
- `ManagedRuntime`: bundled payload with compiled hashes, private root-owned session snapshots, frozen no-DNS script digest. Do not accept arbitrary executable or script paths.
- `DependencyInstaller`: recognized legacy-rule revocation and managed-path reset only. No network installer, package manager execution or passwordless sudo grants.
- `ResolverFileManager`: validated domain/IP inputs, root-side provenance checks, root-local staging and explicit system authorization. Never overwrite another tool's resolver files.
- `AppLogger`: private local files, three-day daily cleanup, 2 MiB daily limit. Never emit raw VPN output or credentials to files/system logs.
- No Sparkle, personal update feed or automatic login-item opt-in.

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
