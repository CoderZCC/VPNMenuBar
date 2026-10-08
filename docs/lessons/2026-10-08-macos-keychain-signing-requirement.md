---
title: Validate signing before adopting Data Protection Keychain on macOS
date: 2026-10-08
tags: [macos, keychain, signing, migration]
severity: high
---

## Symptom

An isolated synthetic-item probe using `KeychainCredentialStore` fails with `errSecMissingEntitlement` (`-34018`) under the current unsigned build setup, even though compilation and in-memory migration tests pass.

## Root Cause

On macOS, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` requires Data Protection Keychain semantics. Its access groups derive from the executable's valid signing entitlements. The original `project.yml` disabled code signing and provided no Keychain access entitlement. Setting the accessibility attribute alone does not establish that access.

## Wrong Path

Do not drop `kSecUseDataProtectionKeychain` to make the error disappear: a legacy file-based Keychain does not implement this accessibility contract. No such fallback was implemented. Passing unit tests or an unsigned build does not demonstrate successful protected storage.

## Fix

The implementation uses Data Protection Keychain, device-only unlocked accessibility and no synchronization. It explicitly reports missing entitlements and preserves legacy JSON if migration cannot complete. The project now enables signing, Hardened Runtime and a bundle-scoped Keychain entitlement. The remaining prerequisite is the confirmed Apple Developer Team and a matching authorized provisioning profile, followed by signed-App verification. Keep the access group stable across updates.

Migration creates and verifies a new Keychain item before committing settings. Never update the old item in place before JSON commits: a write failure could otherwise pair an old gateway/account with new credentials. Retired references are recorded in the committed settings so cleanup can resume after interruption. Abrupt termination before the JSON commit can leave an unreferenced protected item; external backups and filesystem snapshots are not wiped.

## Prevention

- Code: keep settings serialization on an explicit allowlist; never fall back to plaintext. Distinguish locked, inaccessible and missing credentials. Require an explicit recovery action to replace a missing item.
- Process: signed-App acceptance must cover save/relaunch, legacy migration, locked-device access, missing-item recovery and update continuity. Do not claim this release-ready based only on a compile-only build or an unsigned probe.
- Detection: `bash tests/run-config-tests.sh` validates storage invariants using synthetic data. `--keychain-smoke` additionally probes a randomly named real item; the current unsigned executable is expected to be blocked, not pass.

## References

- [Apple: kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Apple: kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible)
- [Apple: Troubleshooting -34018 Keychain Errors](https://developer.apple.com/forums/thread/114456)
- `VPNMenuBar/Config/CredentialStore.swift`
- `VPNMenuBar/Config/ConfigStore.swift`
- `tests/ConfigStoreTests.swift`
