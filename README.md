# VPN MenuBar

A macOS 13+ menu-bar front-end for a bundled OpenConnect runtime. This source is being hardened for managed deployment. **It is not a ready-to-distribute release:** production signing, notarization and managed-device acceptance are still pending. The Bundle ID is `io.coderzcc.vpnmenubar`; local builds use ad-hoc signing without a developer account. Historical `.app` and `.zip` files in the repository do not contain these changes.

## Security and behavior

- Password prefixes and TOTP secrets use local AES-256-GCM encryption. Each record has a random key in a separate local file. Records/directories are private (0600/0700); JSON contains only settings and an opaque reference. **A process running as the same user can read both key and ciphertext. This is not Keychain-equivalent protection.**
- Each VPN session uses macOS system authorization. The app never grants passwordless sudo. Authorization completes before generating the OTP.
- Credentials travel through private FIFOs, not AppleScript, argv or regular files. Closing the control pipe ends only that session's child. No global process kill or pre-connect arbitrary route deletion is used.
- OpenConnect, its libraries and the frozen no-DNS script ship inside the App. Compiled SHA-256 hashes are checked before use and again on a private root-owned per-session copy. Disconnect cleanup removes this temporary copy; no runtime or helper is installed in `/Library`. Homebrew and Command Line Tools are not runtime dependencies.
- Updates are distributed by IT/MDM. Sparkle and the personal GitHub update feed have been removed from the app.
- Launch at login is opt-in. Explicit existing preferences remain respected. Native OpenConnect User-Agent is the default; overrides require VPN administrator approval.
- Raw VPN output stays in a bounded memory buffer. Only fixed error classifications leave it. Log files are created with 0600 permissions, retained for three days with daily cleanup, capped at 2 MiB per day, and are not mirrored to system logs.
- DNS changes remain opt-in, scoped and system-authorized. Unmanaged resolver files and symlinks are rejected. Rules capturing the VPN gateway are refused.

System authorization may require administrator credentials during automatic reconnect. This version does not promise unattended reconnection. An IT-installed restricted helper would be a separate architecture change.

## Build and deploy

Use [the deployment checklist](docs/security-deployment.md) and [the Chinese setup guide](INSTALL.md). Do not reuse the old ad-hoc release or sudoers recipes.

Build machines need Xcode, XcodeGen, Python 3 and a local OpenConnect build with its libraries. The p11-kit preparation step downloads pinned, hash-verified source archives into `build/` when absent; subsequent packaging is offline and targets the build machine architecture. Ninja is required on the build machine. End-user machines need none of those development dependencies.

```bash
python3 scripts/prepare-isolated-p11.py
python3 scripts/prepare-bundled-runtime.py
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar \
  -configuration Debug -destination 'platform=macOS' \
  build
```

Local credential storage needs no Keychain entitlement or provisioning profile. The default project uses ad-hoc signing with Hardened Runtime. Managed distribution may still require Developer ID signing, notarization and MDM approval.

`install-deps.sh` explains that no separate runtime installation is needed. It downloads nothing and installs no package manager. Its explicit administrator-only `--remove-legacy-sudoers LOGIN` mode removes only recognized, root-owned, app-generated rules. The app also revokes its recognized old rules during authorized session preparation. Other/custom sudoers policies require IT review.

## Configuration and recovery

Settings remain at `~/Library/Application Support/com.example.vpnmenubar/config.json`, mode 0600, to preserve existing installations. Schema 1 plaintext migrates to schema 3 only after encryption and decryption/readback succeed. Records live under `local-credentials/<UUID>/`, containing `key` (32 random bytes) and `sealed` (version header, AES-GCM nonce/ciphertext/tag). The UUID is authenticated as associated data. New saves use a fresh record; old records are removed only after settings commit. Failure preserves the original configuration. External backups and filesystem snapshots are not erased.

Missing keys are never regenerated for existing ciphertext. Use **Re-enter Credentials** to recover missing or damaged records explicitly. Schema 2 belongs to the previous Keychain design: it requires explicit credential re-entry and is never silently interpreted as a local record. Old Keychain items are not read or deleted. **Reconfigure…** handles damaged settings JSON. Backing up both ciphertext and its key allows recovery on another machine; this storage is not device-bound. Do not downgrade to versions expecting plaintext secrets.

## Tests

```bash
bash tests/run-local-credential-tests.sh
bash tests/run-config-tests.sh
bash tests/run-controller-tests.sh
bash tests/run-security-tests.sh
```

Tests use synthetic data and temporary directories, including real local encryption/decryption without signing entitlements. The supervisor fixture is unprivileged and does not start a VPN. These checks do not prove system authorization, root lifecycle, real routes/DNS or MDM acceptance.
