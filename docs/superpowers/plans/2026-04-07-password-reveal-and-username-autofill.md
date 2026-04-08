# Password Reveal & Username Auto-fill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an eye-toggle "show/hide" button to the `Password prefix` and `TOTP secret` fields, and extend QR-image import so the username is auto-filled from the otpauth URI label (only when the username field is currently empty).

**Architecture:** A new reusable SwiftUI `RevealableSecureField` component swaps between `SecureField` and `TextField` based on a private `@State` toggle. `QRCodeSecretExtractor` is reshaped to return an `OTPAuthInfo` struct (`secret` + optional `account`). `ImportSecretFromImageButton` gains a second `@Binding var username: String` and writes the parsed account back only when the current username is empty. Both `OnboardingView.credentialsStep` and `SettingsView` Required section swap their two `SecureField`s for `RevealableSecureField` and pass the new `username` binding into the import button.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation `URLComponents`, AppKit (`NSOpenPanel` already in place), no new external dependencies.

**Reference spec:** `docs/superpowers/specs/2026-04-07-password-reveal-and-username-autofill-design.md`

**Project conventions to obey** (from `CLAUDE.md`):
- All user-facing strings are English literals; no i18n framework
- Tests: **none**. Verification is `xcodebuild ... build` + manual smoke test
- New `.swift` files under `VPNMenuBar/` are picked up by the recursive sources glob — no `xcodegen generate` needed
- Commit messages: `type: English description` (`feat`, `fix`, `refactor`, `docs`, `style`, `test`, `chore`)
- Comments in code: extremely sparse; if needed, English

---

## File Structure

```
VPNMenuBar/UI/RevealableSecureField.swift       ← NEW: reusable eye-toggle field
VPNMenuBar/Core/QRCodeSecretExtractor.swift     ← MODIFY: return OTPAuthInfo struct, add account parsing
VPNMenuBar/UI/ImportSecretFromImageButton.swift ← MODIFY: add username @Binding, conditional fill
VPNMenuBar/UI/OnboardingView.swift              ← MODIFY: swap two SecureFields, pass username binding
VPNMenuBar/UI/SettingsView.swift                ← MODIFY: swap two SecureFields, pass username binding
```

No changes to `project.yml`, `VPNConfig`, `ConfigStore`, `TOTPGenerator`, `OpenConnectProcess`, `VPNController`, or `QRExtractError`.

---

## Build verification command (used in every task)

```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```

Expected: terminates with `** BUILD SUCCEEDED **`. Any compile error → fix before moving on. SourceKit cross-file diagnostics ("Cannot find type X in scope") are noise per `CLAUDE.md`; trust `xcodebuild` output.

---

## Task 1: Create `RevealableSecureField`

**Files:**
- Create: `VPNMenuBar/UI/RevealableSecureField.swift`

- [ ] **Step 1: Write the complete file**

```swift
import SwiftUI

struct RevealableSecureField: View {
    let title: String
    @Binding var text: String

    @State private var isVisible: Bool = false

    var body: some View {
        HStack {
            Group {
                if isVisible {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            Button {
                isVisible.toggle()
            } label: {
                Image(systemName: isVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isVisible ? "Hide" : "Show")
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add VPNMenuBar/UI/RevealableSecureField.swift
git commit -m "feat(ui): add RevealableSecureField with eye-toggle"
```

---

## Task 2: Reshape `QRCodeSecretExtractor` to return `OTPAuthInfo`

**Files:**
- Modify: `VPNMenuBar/Core/QRCodeSecretExtractor.swift` (rewrite the `QRCodeSecretExtractor` enum body and add the `OTPAuthInfo` struct; `QRExtractError` stays untouched)

- [ ] **Step 1: Read the current file** to understand its exact shape

Read `VPNMenuBar/Core/QRCodeSecretExtractor.swift`. The relevant section to modify starts at the `enum QRCodeSecretExtractor` declaration. Above it, the `enum QRExtractError` block stays exactly as it is.

- [ ] **Step 2: Replace the `QRCodeSecretExtractor` enum**

Replace the entire `enum QRCodeSecretExtractor { ... }` block with:

```swift
struct OTPAuthInfo: Equatable {
    let secret: String
    let account: String?
}

enum QRCodeSecretExtractor {
    /// Load the image at `url`, find a QR code, parse it as an otpauth://totp URI,
    /// and return the validated Base32 `secret` plus an optional `account` derived
    /// from the URI label. Synchronous — call from a background Task.
    static func extract(fromImageAt url: URL) throws -> OTPAuthInfo {
        guard
            let nsImage = NSImage(contentsOf: url),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw QRExtractError.imageLoadFailed
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw QRExtractError.noQRCodeFound
        }

        guard
            let observation = request.results?.first,
            let payload = observation.payloadStringValue
        else {
            throw QRExtractError.noQRCodeFound
        }

        guard
            let components = URLComponents(string: payload),
            components.scheme?.lowercased() == "otpauth",
            components.host?.lowercased() == "totp"
        else {
            throw QRExtractError.notOtpauthURI
        }

        guard
            let rawSecret = components.queryItems?
                .first(where: { $0.name.lowercased() == "secret" })?
                .value,
            !rawSecret.isEmpty
        else {
            throw QRExtractError.missingSecret
        }

        do {
            _ = try TOTPGenerator.base32Decode(rawSecret)
        } catch {
            throw QRExtractError.invalidBase32
        }

        let account = parseAccount(from: components.path)
        return OTPAuthInfo(secret: rawSecret, account: account)
    }

    /// Parse the account name from the otpauth URI path component.
    /// Returns nil when the result is empty after normalization.
    private static func parseAccount(from rawPath: String) -> String? {
        var label = rawPath
        if label.hasPrefix("/") { label.removeFirst() }
        guard let decoded = label.removingPercentEncoding else { return nil }

        var account = decoded
        if let colonIndex = account.firstIndex(of: ":") {
            account = String(account[account.index(after: colonIndex)...])
        }
        if let atIndex = account.firstIndex(of: "@") {
            account = String(account[..<atIndex])
        }

        let trimmed = account.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

The `enum QRExtractError` block above this **must remain unchanged**. The imports (`Foundation`, `AppKit`, `Vision`) stay as they are.

- [ ] **Step 3: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD FAILED **` is acceptable here ONLY because `ImportSecretFromImageButton` still calls the now-deleted `extractSecret` function. Read the error to confirm the only compile failure is in `ImportSecretFromImageButton.swift` calling `QRCodeSecretExtractor.extractSecret(fromImageAt:)`. If there's any OTHER error in `QRCodeSecretExtractor.swift` itself, fix it before continuing.

If the only failure is the expected one in `ImportSecretFromImageButton`, proceed. Task 3 fixes it.

- [ ] **Step 4: Commit**

```sh
git add VPNMenuBar/Core/QRCodeSecretExtractor.swift
git commit -m "refactor(totp): return OTPAuthInfo with optional account from QR extractor"
```

Note: this commit intentionally leaves the build broken for one commit. Task 3's commit restores green. If you prefer green-at-every-commit, you can defer this commit and do a single combined commit at the end of Task 3.

---

## Task 3: Update `ImportSecretFromImageButton` to consume `OTPAuthInfo` and fill username

**Files:**
- Modify: `VPNMenuBar/UI/ImportSecretFromImageButton.swift`

- [ ] **Step 1: Read the current file** to confirm its exact contents

Read `VPNMenuBar/UI/ImportSecretFromImageButton.swift`.

- [ ] **Step 2: Replace the file with the updated version**

Write the file with these exact contents:

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportSecretFromImageButton: View {
    @Binding var secret: String
    @Binding var username: String

    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pickFile) {
                Text("Import from QR image…")
            }
            .disabled(isImporting)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .alert("Import failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .webP]
        panel.prompt = "Import"
        panel.message = "Select an image containing a TOTP QR code."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let info = try QRCodeSecretExtractor.extract(fromImageAt: url)
                await MainActor.run {
                    self.secret = info.secret
                    if self.username.isEmpty, let account = info.account {
                        self.username = account
                    }
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isImporting = false
                }
            }
        }
    }
}
```

Key changes from the previous version:
- New `@Binding var username: String` property
- `extractSecret(fromImageAt:)` call → `extract(fromImageAt:)`
- Variable `value: String` → `info: OTPAuthInfo`
- New conditional `if self.username.isEmpty, let account = info.account { self.username = account }` inside the success `MainActor.run`

Everything else (alert, NSOpenPanel config, isImporting reset) stays the same.

- [ ] **Step 3: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD FAILED **` is still acceptable IF the only remaining errors are in `OnboardingView.swift` and `SettingsView.swift` complaining that `ImportSecretFromImageButton.init(secret:)` no longer matches (now requires `username:`). Confirm those are the only failures, then proceed. Tasks 4 and 5 fix the call sites.

If `ImportSecretFromImageButton.swift` itself has any error, fix it before continuing.

- [ ] **Step 4: Commit**

```sh
git add VPNMenuBar/UI/ImportSecretFromImageButton.swift
git commit -m "feat(ui): import button auto-fills username when empty"
```

---

## Task 4: Update `OnboardingView.credentialsStep`

**Files:**
- Modify: `VPNMenuBar/UI/OnboardingView.swift` (only the `credentialsStep` computed property)

- [ ] **Step 1: Read the current `credentialsStep`** in `VPNMenuBar/UI/OnboardingView.swift`

It currently looks like:

```swift
    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials").font(.title2).bold()
            TextField("Username", text: $config.username)
            SecureField("Password prefix", text: $config.passwordPrefix)
            SecureField("TOTP secret (Base32)", text: $config.totpSecret)
            HStack {
                ImportSecretFromImageButton(secret: $config.totpSecret)
                Spacer()
            }
            Text("These three fields are required. Defaults for gateway, cert pin, and paths are already filled in and can be edited later in Settings → Advanced.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
```

- [ ] **Step 2: Replace `credentialsStep`** with:

```swift
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
```

Three changes:
- `SecureField("Password prefix", text: $config.passwordPrefix)` → `RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)`
- `SecureField("TOTP secret (Base32)", text: $config.totpSecret)` → `RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)`
- `ImportSecretFromImageButton(secret: $config.totpSecret)` → `ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)`

Do NOT touch any other part of `OnboardingView.swift`. Do NOT add new imports — `RevealableSecureField` is in the same module.

- [ ] **Step 3: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD FAILED **` is still acceptable IF the only remaining error is in `SettingsView.swift` calling the old `ImportSecretFromImageButton.init(secret:)`. Task 5 fixes the last call site. If there's any other error, fix it.

- [ ] **Step 4: Commit**

```sh
git add VPNMenuBar/UI/OnboardingView.swift
git commit -m "feat(onboarding): use RevealableSecureField and pass username binding"
```

---

## Task 5: Update `SettingsView` Required section

**Files:**
- Modify: `VPNMenuBar/UI/SettingsView.swift` (only the `Required` `Section`)

- [ ] **Step 1: Read the current `Required` section** in `VPNMenuBar/UI/SettingsView.swift`

It currently looks like:

```swift
            Section("Required") {
                TextField("Username", text: $config.username)
                SecureField("Password prefix", text: $config.passwordPrefix)
                SecureField("TOTP secret (Base32)", text: $config.totpSecret)
                HStack {
                    ImportSecretFromImageButton(secret: $config.totpSecret)
                    Spacer()
                }
            }
```

- [ ] **Step 2: Replace the `Required` section** with:

```swift
            Section("Required") {
                TextField("Username", text: $config.username)
                RevealableSecureField(title: "Password prefix", text: $config.passwordPrefix)
                RevealableSecureField(title: "TOTP secret (Base32)", text: $config.totpSecret)
                HStack {
                    ImportSecretFromImageButton(secret: $config.totpSecret, username: $config.username)
                    Spacer()
                }
            }
```

Same three changes as Task 4: two SecureField → RevealableSecureField, and ImportSecretFromImageButton gets the new `username:` argument.

Do NOT touch any other section. Do NOT add new imports.

- [ ] **Step 3: Build to verify it compiles cleanly**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. This task closes the build chain — green at this commit and all subsequent.

- [ ] **Step 4: Commit**

```sh
git add VPNMenuBar/UI/SettingsView.swift
git commit -m "feat(settings): use RevealableSecureField and pass username binding"
```

---

## Task 6: Manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Launch the freshly built app**

Run:
```sh
APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
open "$APP_SRC"
```

If the app was already running from a previous session, **Quit and re-open** so the new binary is loaded.

- [ ] **Step 2: Run the seven scenarios**

Record PASS/FAIL for each:

1. **Eye toggle on Password prefix (Settings)** — open Settings, type something into Password prefix, click the eye icon. Expected: text becomes plain; icon flips to `eye.slash`. Click again → text becomes masked again; icon back to `eye`.
2. **Eye toggle on TOTP secret (Settings)** — same as above for the TOTP secret field.
3. **Eye toggle on both fields (Onboarding)** — open Onboarding (or trigger setup-incomplete state), step 3 should expose both Revealable fields. Verify both toggles work the same way.
4. **QR import fills username when empty** — clear username field, click "Import from QR image…", pick a real `otpauth://totp/Issuer:account?secret=...` QR. Expected: secret AND username both fill in. Username should be the part after `:` and before `@` if present.
5. **QR import does NOT overwrite existing username** — type a username manually first, then import the same QR. Expected: secret updates; username stays untouched.
6. **QR with no parseable account** — import a QR whose label is empty or only the issuer (e.g., `otpauth://totp/?secret=...` if generator allows). Expected: secret fills, username stays empty (no error).
7. **End-to-end** — successful import + reveal toggles work + click Connect from menu bar. Expected: VPN connects.

- [ ] **Step 3: If everything passes, the feature is complete**

No further commits unless a smoke-test failure required a code change.

---

## Notes for the implementer

- **Tasks 2, 3, 4 commit in a "build broken between commits" sequence.** Each individual task's commit fails to compile until the next task's commit lands. This is intentional: it keeps each commit semantically focused on one file. If you'd rather have green-at-every-commit, you can fold Tasks 2–5 into a single combined commit at the end — but the per-task split is preferred for review clarity. Task 5's commit restores green.
- **Do NOT touch `project.yml`.** New `.swift` files are picked up automatically by the recursive sources glob.
- **SourceKit cross-file errors** ("Cannot find type X in scope") are noise — trust `xcodebuild` output.
- **`account` parsing is intentionally simple** — split on first `:` and first `@`, no email RFC validation, no quoted-local-part handling. The example VPN target uses `firstname.lastname` so this rule is sufficient. Don't over-engineer.
- **`username.isEmpty` check is the contract** — the spec is explicit that auto-fill must NOT overwrite an existing username. Don't change to "always fill" without re-reading the spec.
- **The `RevealableSecureField` button uses `.borderless`** so it does not visually intrude in the `Form` of `SettingsView` or expand the row height. Don't switch to `.bordered` without smoke-testing that Form doesn't break.
- **No tests required.** Verification is `xcodebuild build` + Task 6's smoke test.
