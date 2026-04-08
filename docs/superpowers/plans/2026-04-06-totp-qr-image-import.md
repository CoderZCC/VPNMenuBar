# TOTP QR Image Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app "Import from QR image…" button to both the Onboarding wizard and Settings panel that recognizes a `otpauth://totp/...` QR code from a user-selected image and fills the TOTP secret field automatically.

**Architecture:** A pure `Core/QRCodeSecretExtractor` enum uses Vision to find a QR in an `NSImage`, parses the otpauth URI with `URLComponents`, and validates the `secret` via the existing `TOTPGenerator.base32Decode`. A reusable SwiftUI `ImportSecretFromImageButton` view drives `NSOpenPanel`, runs the extractor on a background `Task.detached`, and writes the result back through a `@Binding`. Both `OnboardingView` and `SettingsView` mount the same button next to their TOTP `SecureField`.

**Tech Stack:** Swift 5.9, SwiftUI, Vision (`VNDetectBarcodesRequest`), AppKit (`NSImage`, `NSOpenPanel`), `UniformTypeIdentifiers` (`UTType`), CryptoKit (already imported by `TOTPGenerator`).

**Reference spec:** `docs/superpowers/specs/2026-04-06-totp-qr-image-import-design.md`

**Project conventions to obey** (from `CLAUDE.md`):
- All user-facing strings are English literals; no i18n framework
- Tests: **none**. The `VPNMenuBarTests` target was removed. Verification is `xcodebuild ... build` + manual smoke test
- New `.swift` files under `VPNMenuBar/` are picked up by the recursive sources glob — no `xcodegen generate` needed
- Commit messages: `type: English description` (`feat`, `fix`, `refactor`, `docs`, `style`, `test`, `chore`)
- Comments in code: extremely sparse; if needed, English

---

## File Structure

```
VPNMenuBar/Core/QRCodeSecretExtractor.swift     ← NEW: pure logic
VPNMenuBar/UI/ImportSecretFromImageButton.swift ← NEW: SwiftUI component
VPNMenuBar/UI/OnboardingView.swift              ← MODIFY: insert button in credentialsStep
VPNMenuBar/UI/SettingsView.swift                ← MODIFY: insert button in Required section
```

No changes to `project.yml`, `VPNConfig`, `ConfigStore`, `TOTPGenerator`, `OpenConnectProcess`, or `VPNController`.

---

## Build verification command (used in every task)

```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```

Expected: terminates with `** BUILD SUCCEEDED **`. Any compile error → fix before moving on.

---

## Task 1: Create `QRCodeSecretExtractor`

**Files:**
- Create: `VPNMenuBar/Core/QRCodeSecretExtractor.swift`

- [ ] **Step 1: Write the complete file**

```swift
import Foundation
import AppKit
import Vision

enum QRExtractError: Error, LocalizedError, Equatable {
    case imageLoadFailed
    case noQRCodeFound
    case notOtpauthURI
    case missingSecret
    case invalidBase32

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            return "Could not read the selected file as an image."
        case .noQRCodeFound:
            return "No QR code was found in this image."
        case .notOtpauthURI:
            return "The QR code is not a TOTP otpauth URI."
        case .missingSecret:
            return "The otpauth URI does not contain a secret parameter."
        case .invalidBase32:
            return "The secret in the QR code is not valid Base32."
        }
    }
}

enum QRCodeSecretExtractor {
    /// Load the image at `url`, find a QR code, parse it as an otpauth://totp URI,
    /// and return the Base32 `secret` query parameter (validated via TOTPGenerator).
    /// Synchronous — call from a background Task.
    static func extractSecret(fromImageAt url: URL) throws -> String {
        guard
            let nsImage = NSImage(contentsOf: url),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw QRExtractError.imageLoadFailed
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard
            let observation = (request.results ?? []).first as? VNBarcodeObservation,
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

        return rawSecret
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
git add VPNMenuBar/Core/QRCodeSecretExtractor.swift
git commit -m "feat(totp): add QRCodeSecretExtractor for parsing otpauth QR images"
```

---

## Task 2: Create `ImportSecretFromImageButton`

**Files:**
- Create: `VPNMenuBar/UI/ImportSecretFromImageButton.swift`

- [ ] **Step 1: Write the complete file**

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportSecretFromImageButton: View {
    @Binding var secret: String

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
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        panel.prompt = "Import"
        panel.message = "Select an image containing a TOTP QR code."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isImporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let value = try QRCodeSecretExtractor.extractSecret(fromImageAt: url)
                await MainActor.run {
                    self.secret = value
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

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add VPNMenuBar/UI/ImportSecretFromImageButton.swift
git commit -m "feat(ui): add ImportSecretFromImageButton component"
```

---

## Task 3: Wire button into `OnboardingView.credentialsStep`

**Files:**
- Modify: `VPNMenuBar/UI/OnboardingView.swift` (only `credentialsStep`, lines 83–92 in current file)

- [ ] **Step 1: Insert the button under the TOTP `SecureField`**

Replace the body of `credentialsStep`:

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

(Only the new `HStack { ImportSecretFromImageButton… }` block is added; everything else stays the same.)

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add VPNMenuBar/UI/OnboardingView.swift
git commit -m "feat(onboarding): add QR image import next to TOTP secret field"
```

---

## Task 4: Wire button into `SettingsView` Required section

**Files:**
- Modify: `VPNMenuBar/UI/SettingsView.swift` (only the `Required` `Section`, lines 15–19 in current file)

- [ ] **Step 1: Insert the button under the TOTP `SecureField`**

Replace the `Required` section:

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

- [ ] **Step 2: Build to verify it compiles**

Run:
```sh
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add VPNMenuBar/UI/SettingsView.swift
git commit -m "feat(settings): add QR image import next to TOTP secret field"
```

---

## Task 5: Manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Launch the freshly built app**

Run:
```sh
APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
open "$APP_SRC"
```

- [ ] **Step 2: Test five scenarios**

For each, record PASS/FAIL:

1. **Real otpauth QR** — open Settings, click "Import from QR image…", pick a screenshot of a real `otpauth://totp/...` QR (e.g. one generated at https://stefansundin.github.io/2fa-qr/ for testing). Expected: `SecureField` is filled with the Base32 secret; no alert.
2. **Random photo without a QR** — pick any normal image. Expected: alert "Import failed" with body "No QR code was found in this image."
3. **Non-otpauth QR** — pick an image of a QR encoding a plain URL (e.g. https://example.com). Expected: alert with body "The QR code is not a TOTP otpauth URI."
4. **Cancel the open panel** — click "Import…" and press Cancel. Expected: nothing happens; no alert; existing field value untouched.
5. **End-to-end** — after a successful import in Onboarding (or Settings → Save), click Connect from the menu bar. Expected: VPN connects normally (TOTP generated from the imported secret was accepted).

- [ ] **Step 3: If everything passes, the feature is complete**

No further commits unless a smoke-test failure required code changes.

---

## Notes for the implementer

- **Do NOT touch `project.yml`.** New `.swift` files under `VPNMenuBar/` are picked up automatically by the recursive `sources` glob; running `xcodegen generate` would needlessly rewrite `VPNMenuBar.xcodeproj` (which is `.gitignore`d but still churns local state).
- **SourceKit may show "Cannot find type X in scope" errors in single-file view.** Per `CLAUDE.md`, that's noise — trust `xcodebuild` output.
- **`Task.detached` is intentional** in `ImportSecretFromImageButton.pickFile()` — Vision's `perform` blocks for tens to hundreds of milliseconds on large images; running it on the main actor would freeze the panel UI. Results are written back via `await MainActor.run` because `@Binding` mutations need to happen on the main actor.
- **Do NOT normalize the secret** (no uppercasing, no whitespace stripping in `QRCodeSecretExtractor`). `TOTPGenerator.base32Decode` already handles those cases at code-generation time, and preserving the operator-supplied format makes config diffs easier to compare.
- **`isImporting` is reset in both success and failure paths**, including inside `MainActor.run`. Don't move it outside the closures — `Task.detached` is fire-and-forget and the outer `pickFile()` returns immediately.
- **No tests required.** The project has no test target (`CLAUDE.md` "Tests: none"). Verification is `xcodebuild build` + Task 5's smoke test.
