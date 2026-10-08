# Managed deployment and remaining acceptance gates

## Runtime contract

The reviewed runtime is packaged at:

```
VPNMenuBar.app/Contents/Resources/BundledRuntime/
  openconnect
  vpnc-script--no-dns
  ... approved dylibs using @loader_path within this directory ...
```

The application now includes OpenConnect, its dynamic libraries and the pinned no-DNS script. End-user machines need neither Homebrew nor Apple Command Line Tools. Run `python3 scripts/build-compatible-runtime.py` before XcodeGen on an Apple Silicon build machine with the documented build tools. This uses pinned, hash-verified source archives and an explicit macOS 13 deployment target; dependency installation is staged under `build/`, not system directories. The packager rewrites non-system load commands to `@loader_path`, removes rpaths, verifies the closed dependency graph, ad-hoc signs each image and generates compiled SHA-256 hashes. It also gathers available package license notices and SBOMs. Review corresponding-source and redistribution requirements before external distribution.

The compatibility build targets arm64 and macOS 13. Packaging inspects each Mach-O minimum OS version and rejects a library requiring a newer system; the Xcode build also rejects a mismatching OpenConnect architecture. Validation on the current macOS 26 host does not establish acceptance on macOS 13, 14 or 15: real-device connection, routing/DNS cleanup and sleep/reconnect checks remain required. An Intel or universal release requires matching runtime/library slices and separate validation.

Configuration paths do not select executables. The app checks the bundled bytes, then administrator authorization creates a private root-owned session under `/var/run`. Each expected file is copied into its 0700 runtime subdirectory and its hash is checked again before execution. Files are mode 0500. The supervisor runs the snapshot, so subsequent bundle edits cannot change its executable or libraries. No root process executes a binary directly from the user-writable bundle. Normal session cleanup removes the snapshot. A force-killed supervisor may leave temporary files until cleanup/reboot; no launch daemon or persistent runtime is installed.

Existing `/Library/Application Support/VPNMenuBar/Runtime` files are unused and are not automatically removed. Existing per-domain `/etc/resolver` configuration remains independently managed. Administrator authorization and company policy still apply.

## Authorization and migration

The app invokes macOS system authorization for session preparation. It verifies the runtime again inside the privileged operation and revokes only recognized current-user app-generated sudoers files. Custom/global rules require separate IT review. Nothing grants lasting passwordless rights.

The root supervisor owns a freshly created session directory under `/var/run`. Credential and control FIFOs are 0600 and owned by the initiating UID; the containing directory is root-owned. The credential is never in AppleScript arguments or a regular file. Closing control stops only the supervised child. An unattached session times out. Runtime output remains in a bounded in-memory buffer; only fixed error classifications reach logs/UI. FIFO permissions prevent other accounts from accessing credentials; they do not isolate processes running under the same user.

Automatic reconnect may request administrator authorization. No unconditional route scrub or global `pkill` remains. Verify the frozen script's routing cleanup on each supported gateway and network transition.

DNS changes preserve the gateway-domain guard, reject unmanaged/symlink destinations and stage replacement content inside the root-owned resolver directory. Validate conflict handling and authorization cancellation on a test machine before distribution.

## Local credential storage and distribution

The user selected local encryption in place of Keychain. Production uses `LocalCredentialStore`: AES-256-GCM, random 256-bit per-record keys, authenticated UUID references, 0600 key/ciphertext files and 0700 record directories. The key is stored on the same computer. Same-user processes or anyone who obtains both files can decrypt the credentials; there is no device binding or lock-screen access control. This does not close the original corporate credential-storage risk to the same standard as Keychain.

Schema 1 plaintext migrates to schema 3 only after encrypted readback verifies both secrets. Failure preserves the original. Schema 2 is the earlier Keychain format and requires explicit re-entry; the app does not access or delete those Keychain items. Missing keys are never silently replaced. Settings remain in the historical directory to preserve migration access.

The Bundle ID is `io.coderzcc.vpnmenubar`. Local builds use ad-hoc signing with Hardened Runtime, without Keychain entitlements, provisioning profiles or a developer account. For managed distribution, Developer ID signing, notarization and organization approval remain separate release work. The previously authorized DAYPOP identity was used for the staged test runtime; no company account is required for local credential storage.

Distribute approved releases via IT/MDM. The app has no embedded updater. Historical repository release artifacts have not been rebuilt or republished.

## Verification performed vs. pending

Automated checks cover real local encryption/decryption, schema migration/failure recovery, credential availability state transitions, cancellation, runtime path policy, script digest, command boundaries, DNS input/provenance guards, log permissions/retention and real FIFO/supervisor behavior using a non-root fake process in a temporary directory. Compile-only builds do not prove signed runtime behavior.

Additional execution tests exercise resolver creation/replacement, readable directory and file modes, rejection of unmanaged/symlink/writable destinations, recognized legacy-rule removal, and rejected unmanaged/symlink rules. These redirect generated commands into temporary directories, substitute the test UID for root ownership, and disable chown, DNS reload and system visudo. They do not validate actual root ownership, DNS resolution or installed sudoers syntax. Controller fixtures verify authorization cancellation before credential submission and failed teardown retaining active-process state. Supervisor fixtures cover control EOF, TERM and HUP; SIGKILL cannot run shell cleanup traps.

Local evidence on 2026-10-08: the previous bundled App (0.2.24) connected successfully on the current macOS 26 machine. The macOS 13-targeted 0.2.25 rebuild passed the Release build, strict ad-hoc signature verification, all 14 Mach-O minimum-version checks, OpenConnect feature comparison and the security regression suite, including actual GnuTLS/p11-kit isolation checks. The isolated p11-kit rebuild passed 44 upstream tests. These results do not establish real connection or compatibility on an older OS. Real macOS 13/14/15 connect/disconnect, routing/DNS cleanup, sleep/reconnect and managed-device acceptance remain pending. No old-OS test device was available during this build.

## Isolated crypto configuration and packaging

The supervisor explicitly sets `GNUTLS_SYSTEM_PRIORITY_FILE=/dev/null` and `P11_KIT_NO_USER_CONFIG=1`. P11-kit 0.26.5 is rebuilt from its verified source archive with system, user and module paths under `/var/empty/vpnmenubar`, with the trust module disabled. No files are installed there. macOS system trust and the configured server pin remain available. This build intentionally does not support external PKCS#11 tokens or Homebrew TLS configuration.

Packaging completes in a temporary directory before publishing the payload, license notices and compiled hashes. A failed publication restores the previous files. A lock blocks concurrent packaging and builds during publication; after an abrupt process kill, inspect the staged/backup state before removing a stale `build/runtime-packaging.lock`. Every Xcode build checks the exact file inventory, hashes and architecture. Build-time tools and source archives remain under `build/`, not system directories.
