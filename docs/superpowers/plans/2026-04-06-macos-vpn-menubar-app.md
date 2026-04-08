# macOS VPN MenuBar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS 13+ status-bar app that replaces `vpn.py`: manages openconnect-based VPN connections with a menu UI, settings panel, dependency checks, and login-at-startup support.

**Architecture:** SwiftUI + `MenuBarExtra(.menu)` front end; `VPNController` (ObservableObject) owns a state machine that spawns `sudo openconnect` via a protocol-abstracted `OpenConnectProcessRunning`; config stored as 0600 JSON under `~/Library/Application Support/com.example.vpnmenubar/`; all user-facing strings are English literals (no i18n framework).

**Tech Stack:** Swift 5.9+, SwiftUI, CryptoKit (HMAC-SHA1 for TOTP), Foundation `Process`, `ServiceManagement` (`SMAppService`), `UserNotifications`, XcodeGen for reproducible project generation.

**Reference spec:** `docs/superpowers/specs/2026-04-06-macos-vpn-menubar-app-design.md`

---

## File Structure

```
VPNMenuBar/                          ← Xcode project root
├── project.yml                      ← XcodeGen input (declarative)
├── VPNMenuBar.xcodeproj             ← generated, git-ignored
├── VPNMenuBar/                      ← app sources
│   ├── Info.plist
│   ├── Resources/
│   │   └── vpnc-script--no-dns      ← copied from repo root
│   ├── App/
│   │   └── VPNMenuBarApp.swift      ← @main scene wiring
│   ├── Core/
│   │   ├── VPNState.swift
│   │   ├── VPNController.swift
│   │   ├── TOTPGenerator.swift
│   │   ├── ProcessRunning.swift     ← thin Process wrapper + protocol
│   │   └── OpenConnectProcess.swift ← openconnect-specific wrapper
│   ├── Config/
│   │   ├── VPNConfig.swift
│   │   └── ConfigStore.swift
│   ├── Dependencies/
│   │   └── DependencyChecker.swift
│   ├── UI/
│   │   ├── StatusBarIconFactory.swift
│   │   ├── MenuContentView.swift
│   │   ├── SettingsView.swift
│   │   ├── OnboardingView.swift
│   │   └── DependencyAlertView.swift
│   └── Util/
│       └── LoginItemManager.swift
└── VPNMenuBarTests/
    ├── VPNConfigTests.swift
    ├── ConfigStoreTests.swift
    ├── TOTPGeneratorTests.swift
    ├── DependencyCheckerTests.swift
    └── VPNControllerTests.swift
```

**File responsibilities:**

| File | Owns | Depends on |
|---|---|---|
| `VPNConfig.swift` | Codable config struct, field defaults | — |
| `ConfigStore.swift` | Read/write JSON at 0600, atomic save, broken-file backup | `VPNConfig` |
| `TOTPGenerator.swift` | Base32 decode + RFC 6238 TOTP | CryptoKit |
| `VPNState.swift` | 4-state enum + Equatable | — |
| `ProcessRunning.swift` | `ProcessRunning` protocol + `SystemProcessRunner` production impl for `exit-code + stdout/stderr` one-shot commands | Foundation |
| `OpenConnectProcess.swift` | `OpenConnectProcessRunning` protocol + `OpenConnectProcess` long-running process wrapper (stdin write, stderr pipe, pid tracking) | Foundation |
| `DependencyChecker.swift` | Check openconnect/sudoers/vpnc-script, return `[DependencyStatus]` | `ProcessRunning`, `VPNConfig` |
| `VPNController.swift` | State machine; `connect/disconnect/reconnect` API; publishes `@Published var state` | `VPNConfig`, `ConfigStore`, `DependencyChecker`, `OpenConnectProcessRunning`, `TOTPGenerator` |
| `StatusBarIconFactory.swift` | `NSImage` composition: SF Symbol + colored dot overlay per state | AppKit |
| `MenuContentView.swift` | SwiftUI view rendering menu items; binds to `VPNController` | `VPNController` |
| `SettingsView.swift` | SwiftUI Form: required + advanced disclosure + launch-at-login toggle | `VPNController`, `LoginItemManager` |
| `OnboardingView.swift` | 4-step wizard window | `VPNController`, `DependencyChecker` |
| `DependencyAlertView.swift` | Status list + fix hints + Copy/Recheck | `DependencyChecker` |
| `LoginItemManager.swift` | `SMAppService.mainApp` register/unregister | ServiceManagement |
| `VPNMenuBarApp.swift` | `@main`, `MenuBarExtra` scene, `Settings` scene, window coordinator | everything |

**Task count:** 16 tasks (Task 0 through Task 15).

---

## Task 0: Bootstrap project with XcodeGen

**Files:**
- Create: `.gitignore`
- Create: `project.yml`
- Create: `VPNMenuBar/Info.plist`
- Create: `VPNMenuBar/App/VPNMenuBarApp.swift`
- Create: `VPNMenuBarTests/SmokeTest.swift`

- [ ] **Step 1: Install xcodegen via Homebrew**

Run: `brew list xcodegen >/dev/null 2>&1 || brew install xcodegen`
Expected: xcodegen on PATH. Verify: `xcodegen --version` prints a version number.

- [ ] **Step 2: Initialise git repository at `/Users/ccz/Desktop/r100/vpn`**

Run:
```bash
cd /Users/ccz/Desktop/r100/vpn
git init
git add vpn.py vpnc-script--no-dns CLAUDE.md docs/
git commit -m "chore: initial snapshot of existing vpn.py helper and design docs"
```
Expected: first commit created on `master` (or `main`).

- [ ] **Step 3: Create `.gitignore`**

Create `/Users/ccz/Desktop/r100/vpn/.gitignore`:

```gitignore
# macOS
.DS_Store

# Xcode
*.xcodeproj/
*.xcworkspace/
xcuserdata/
DerivedData/
build/
*.hmap
*.ipa

# Superpowers visual companion
.superpowers/
```

- [ ] **Step 4: Create `project.yml` for XcodeGen**

Create `/Users/ccz/Desktop/r100/vpn/project.yml`:

```yaml
name: VPNMenuBar
options:
  bundleIdPrefix: com.example
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGNING_REQUIRED: NO
    CODE_SIGNING_ALLOWED: NO
    ENABLE_HARDENED_RUNTIME: NO
    ENABLE_APP_SANDBOX: NO

targets:
  VPNMenuBar:
    type: application
    platform: macOS
    sources:
      - path: VPNMenuBar
    info:
      path: VPNMenuBar/Info.plist
      properties:
        CFBundleName: VPNMenuBar
        CFBundleDisplayName: VPN MenuBar
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSMinimumSystemVersion: "13.0"
        LSUIElement: true
        NSUserNotificationAlertStyle: alert
        NSHumanReadableCopyright: "Personal use only"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.vpnmenubar
        INFOPLIST_FILE: VPNMenuBar/Info.plist
        ASSETCATALOG_COMPILER_APPICON_NAME: ""

  VPNMenuBarTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: VPNMenuBarTests
    dependencies:
      - target: VPNMenuBar
    settings:
      base:
        BUNDLE_LOADER: $(TEST_HOST)
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/VPNMenuBar.app/Contents/MacOS/VPNMenuBar

schemes:
  VPNMenuBar:
    build:
      targets:
        VPNMenuBar: all
        VPNMenuBarTests: [test]
    test:
      targets:
        - VPNMenuBarTests
    run:
      config: Debug
```

- [ ] **Step 5: Create empty Info.plist placeholder**

Create `/Users/ccz/Desktop/r100/vpn/VPNMenuBar/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

XcodeGen's `info.properties` in `project.yml` will merge into this on generation.

- [ ] **Step 6: Create the minimal `VPNMenuBarApp.swift` entry point**

Create `/Users/ccz/Desktop/r100/vpn/VPNMenuBar/App/VPNMenuBarApp.swift`:

```swift
import SwiftUI

@main
struct VPNMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("VPN", systemImage: "lock.shield") {
            Text("VPN MenuBar — bootstrap")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 7: Create a trivial smoke test so the test bundle compiles**

Create `/Users/ccz/Desktop/r100/vpn/VPNMenuBarTests/SmokeTest.swift`:

```swift
import XCTest

final class SmokeTest: XCTestCase {
    func testTrue() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 8: Generate the Xcode project**

Run:
```bash
cd /Users/ccz/Desktop/r100/vpn
xcodegen generate
```
Expected: `VPNMenuBar.xcodeproj` directory created, `Generated project successfully` in output.

- [ ] **Step 9: Build the project from the command line**

Run:
```bash
xcodebuild \
  -project VPNMenuBar.xcodeproj \
  -scheme VPNMenuBar \
  -destination 'platform=macOS' \
  -configuration Debug \
  build 2>&1 | tail -30
```
Expected: `** BUILD SUCCEEDED **` at the end.

- [ ] **Step 10: Run the unit test bundle to confirm tests wire up**

Run:
```bash
xcodebuild \
  -project VPNMenuBar.xcodeproj \
  -scheme VPNMenuBar \
  -destination 'platform=macOS' \
  test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` at the end.

- [ ] **Step 11: Commit**

```bash
git add .gitignore project.yml VPNMenuBar/ VPNMenuBarTests/
git commit -m "chore: bootstrap Xcode project with XcodeGen and empty MenuBarExtra"
```

---

## Task 1: VPNConfig Codable model

**Files:**
- Create: `VPNMenuBar/Config/VPNConfig.swift`
- Create: `VPNMenuBarTests/VPNConfigTests.swift`

- [ ] **Step 1: Write failing round-trip test**

Create `VPNMenuBarTests/VPNConfigTests.swift`:

```swift
import XCTest
@testable import VPNMenuBar

final class VPNConfigTests: XCTestCase {
    func testEncodeDecodeRoundTrip() throws {
        let original = VPNConfig(
            username: "alice",
            passwordPrefix: "pw-",
            totpSecret: "JBSWY3DPEHPK3PXP"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VPNConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDefaultsForAdvancedFields() {
        let c = VPNConfig(username: "a", passwordPrefix: "b", totpSecret: "c")
        XCTAssertEqual(c.gateway, "vpn.example.com")
        XCTAssertEqual(c.openconnectPath, "/opt/homebrew/bin/openconnect")
        XCTAssertFalse(c.skipDNSModification)
        XCTAssertEqual(c.schemaVersion, 1)
    }

    func testIsConfiguredRequiresAllThreeFields() {
        XCTAssertFalse(VPNConfig(username: "",  passwordPrefix: "p", totpSecret: "t").isConfigured)
        XCTAssertFalse(VPNConfig(username: "u", passwordPrefix: "",  totpSecret: "t").isConfigured)
        XCTAssertFalse(VPNConfig(username: "u", passwordPrefix: "p", totpSecret: "").isConfigured)
        XCTAssertTrue (VPNConfig(username: "u", passwordPrefix: "p", totpSecret: "t").isConfigured)
    }
}
```

- [ ] **Step 2: Regenerate project and run tests to confirm failure**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: compile error `cannot find 'VPNConfig' in scope`.

- [ ] **Step 3: Create `VPNConfig.swift`**

Create `VPNMenuBar/Config/VPNConfig.swift`:

```swift
import Foundation

struct VPNConfig: Codable, Equatable {
    // Required — collected by Onboarding
    var username: String
    var passwordPrefix: String
    var totpSecret: String

    // Advanced — defaults migrated from vpn.py
    var gateway: String = "vpn.example.com"
    var serverCertPin: String = "pin-sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    var openconnectPath: String = "/opt/homebrew/bin/openconnect"
    var vpncScriptPath: String = "/opt/homebrew/Cellar/openconnect/9.12_1/.bottle/etc/vpnc/vpnc-script"
    var skipDNSModification: Bool = false

    // Meta
    var schemaVersion: Int = 1

    var isConfigured: Bool {
        !username.isEmpty && !passwordPrefix.isEmpty && !totpSecret.isEmpty
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `Test Suite 'VPNConfigTests' passed`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add VPNMenuBar/Config/VPNConfig.swift VPNMenuBarTests/VPNConfigTests.swift
git commit -m "feat: add VPNConfig Codable model with defaults migrated from vpn.py"
```

---

## Task 2: ConfigStore (read/write JSON at 0600)

**Files:**
- Create: `VPNMenuBar/Config/ConfigStore.swift`
- Create: `VPNMenuBarTests/ConfigStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `VPNMenuBarTests/ConfigStoreTests.swift`:

```swift
import XCTest
@testable import VPNMenuBar

final class ConfigStoreTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPNMenuBarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadReturnsNilWhenFileMissing() throws {
        let store = ConfigStore(baseDirectory: tempDir)
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTrip() throws {
        let store = ConfigStore(baseDirectory: tempDir)
        let cfg = VPNConfig(username: "alice", passwordPrefix: "pw", totpSecret: "sec")
        try store.save(cfg)
        let loaded = try store.load()
        XCTAssertEqual(loaded, cfg)
    }

    func testSaveSetsPermissions0600() throws {
        let store = ConfigStore(baseDirectory: tempDir)
        try store.save(VPNConfig(username: "u", passwordPrefix: "p", totpSecret: "t"))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
    }

    func testBrokenJSONIsBackedUpAndLoadReturnsNil() throws {
        let store = ConfigStore(baseDirectory: tempDir)
        try FileManager.default.createDirectory(
            at: store.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{ not valid json".write(to: store.configURL, atomically: true, encoding: .utf8)

        let loaded = try store.load()
        XCTAssertNil(loaded)

        // Original file should now be gone and a backup file should exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configURL.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: store.configURL.deletingLastPathComponent().path)
        XCTAssertTrue(contents.contains { $0.hasPrefix("config.json.broken-") })
    }
}
```

- [ ] **Step 2: Regenerate and run to confirm failure**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `cannot find 'ConfigStore' in scope`.

- [ ] **Step 3: Create `ConfigStore.swift`**

Create `VPNMenuBar/Config/ConfigStore.swift`:

```swift
import Foundation

final class ConfigStore {
    private let baseDirectory: URL
    let configURL: URL

    /// Production initializer — writes to ~/Library/Application Support/com.example.vpnmenubar/
    convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        self.init(baseDirectory: appSupport.appendingPathComponent("com.example.vpnmenubar", isDirectory: true))
    }

    /// Test initializer — inject any base directory.
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.configURL = baseDirectory.appendingPathComponent("config.json")
    }

    var isConfigured: Bool {
        (try? load())?.isConfigured ?? false
    }

    func load() throws -> VPNConfig? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return nil }
        let data = try Data(contentsOf: configURL)
        do {
            return try JSONDecoder().decode(VPNConfig.self, from: data)
        } catch {
            try backupBrokenFile()
            return nil
        }
    }

    func save(_ config: VPNConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        // Atomic write: temp file + rename.
        let tmpURL = configURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: configURL.path) {
            _ = try fm.replaceItemAt(configURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: configURL)
        }

        // Enforce 0600.
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configURL.path
        )
    }

    private func backupBrokenFile() throws {
        let fm = FileManager.default
        let epoch = Int(Date().timeIntervalSince1970)
        let backupURL = configURL.appendingPathExtension("broken-\(epoch)")
        try fm.moveItem(at: configURL, to: backupURL)
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `Test Suite 'ConfigStoreTests' passed`, 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add VPNMenuBar/Config/ConfigStore.swift VPNMenuBarTests/ConfigStoreTests.swift
git commit -m "feat: add ConfigStore with atomic 0600 JSON writes and broken-file backup"
```

---

## Task 3: TOTPGenerator (Base32 + RFC 6238)

**Files:**
- Create: `VPNMenuBar/Core/TOTPGenerator.swift`
- Create: `VPNMenuBarTests/TOTPGeneratorTests.swift`

- [ ] **Step 1: Write failing tests with RFC 6238 vectors**

Create `VPNMenuBarTests/TOTPGeneratorTests.swift`:

```swift
import XCTest
@testable import VPNMenuBar

final class TOTPGeneratorTests: XCTestCase {
    // RFC 6238 Appendix B uses the ASCII secret "12345678901234567890"
    // which is Base32-encoded as "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ".
    private let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC6238Vector_ts59() throws {
        let code = try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 8)
        XCTAssertEqual(code, "94287082")
    }

    func testRFC6238Vector_ts1111111109() throws {
        let code = try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 1111111109), digits: 8)
        XCTAssertEqual(code, "07081804")
    }

    func testRFC6238Vector_ts1234567890() throws {
        let code = try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 1234567890), digits: 8)
        XCTAssertEqual(code, "89005924")
    }

    func testSixDigitCodeAtTs59() throws {
        // Truncate the 8-digit vector 94287082 → last 6 digits = 287082.
        let code = try TOTPGenerator.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 6)
        XCTAssertEqual(code, "287082")
    }

    func testInvalidBase32Throws() {
        XCTAssertThrowsError(try TOTPGenerator.code(secret: "!@#$", at: Date(), digits: 6))
    }
}
```

- [ ] **Step 2: Regenerate and run to confirm failure**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `cannot find 'TOTPGenerator' in scope`.

- [ ] **Step 3: Create `TOTPGenerator.swift`**

Create `VPNMenuBar/Core/TOTPGenerator.swift`:

```swift
import Foundation
import CryptoKit

enum TOTPError: Error, Equatable {
    case invalidBase32
}

enum TOTPGenerator {
    /// Compute the TOTP code for the given Base32-encoded secret at the given time.
    /// Follows RFC 6238 with HMAC-SHA1, 30s step, configurable digit count.
    static func code(secret: String, at date: Date = Date(), digits: Int = 6) throws -> String {
        let key = try base32Decode(secret)
        let counter = UInt64(date.timeIntervalSince1970 / 30)

        var bigEndianCounter = counter.bigEndian
        let counterBytes = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }

        let hmac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterBytes,
            using: SymmetricKey(data: key)
        )
        let mac = Data(hmac)

        // Dynamic truncation (RFC 4226 §5.3).
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary =
            (UInt32(mac[offset])     & 0x7f) << 24 |
            (UInt32(mac[offset + 1]) & 0xff) << 16 |
            (UInt32(mac[offset + 2]) & 0xff) << 8  |
            (UInt32(mac[offset + 3]) & 0xff)

        let modulus = UInt32(pow(10.0, Double(digits)))
        let truncated = binary % modulus
        return String(format: "%0\(digits)u", truncated)
    }

    /// Decode an RFC 4648 Base32 string (uppercase, no padding required).
    static func base32Decode(_ input: String) throws -> Data {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let cleaned = input
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: " ", with: "")

        var bits = 0
        var buffer: UInt32 = 0
        var output = Data()

        for char in cleaned {
            guard let index = alphabet.firstIndex(of: char) else {
                throw TOTPError.invalidBase32
            }
            let value = UInt32(alphabet.distance(from: alphabet.startIndex, to: index))
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return output
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: all 5 `TOTPGeneratorTests` pass.

- [ ] **Step 5: Commit**

```bash
git add VPNMenuBar/Core/TOTPGenerator.swift VPNMenuBarTests/TOTPGeneratorTests.swift
git commit -m "feat: add TOTPGenerator with RFC 6238 HMAC-SHA1 and Base32 decoder"
```

---

## Task 4: VPNState enum

**Files:**
- Create: `VPNMenuBar/Core/VPNState.swift`

- [ ] **Step 1: Create `VPNState.swift`**

Create `VPNMenuBar/Core/VPNState.swift`:

```swift
import Foundation

enum VPNState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    case failed(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isBusy: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Short human-readable label for menu display.
    var shortLabel: String {
        switch self {
        case .disconnected:       return "Disconnected"
        case .connecting:         return "Connecting…"
        case .connected:          return "Connected"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}
```

- [ ] **Step 2: Build and run existing tests to make sure nothing broke**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/Core/VPNState.swift
git commit -m "feat: add VPNState enum (disconnected/connecting/connected/failed)"
```

---

## Task 5: ProcessRunning protocol + SystemProcessRunner

**Files:**
- Create: `VPNMenuBar/Core/ProcessRunning.swift`

Purpose: a small, mockable abstraction for **one-shot** command execution (used by `DependencyChecker`). Long-running process management is a separate concern handled by `OpenConnectProcess` in Task 6.

- [ ] **Step 1: Create `ProcessRunning.swift`**

Create `VPNMenuBar/Core/ProcessRunning.swift`:

```swift
import Foundation

/// Result of a one-shot command.
struct ProcessResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over `Process` for one-shot commands. Mockable in tests.
protocol ProcessRunning {
    /// Run the executable synchronously with the given args and return its result.
    /// - Parameters:
    ///   - executable: absolute path to the binary
    ///   - arguments: argv (not including argv[0])
    ///   - timeoutSeconds: if non-nil, the process is SIGTERM'd after the timeout
    ///                     and a result with exitCode = -1 is returned.
    func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult
}

/// Production implementation using Foundation.Process.
final class SystemProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        try p.run()

        if let timeout = timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                p.terminate()
                return ProcessResult(exitCode: -1, stdout: "", stderr: "timeout")
            }
        } else {
            p.waitUntilExit()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/Core/ProcessRunning.swift
git commit -m "feat: add ProcessRunning protocol and SystemProcessRunner for one-shot commands"
```

---

## Task 6: OpenConnectProcess (long-running wrapper)

**Files:**
- Create: `VPNMenuBar/Core/OpenConnectProcess.swift`

No unit tests for the production class (it shells out to real `sudo openconnect`); instead, a `FakeOpenConnectProcess` defined here is used by `VPNControllerTests` in Task 8.

- [ ] **Step 1: Create `OpenConnectProcess.swift`**

Create `VPNMenuBar/Core/OpenConnectProcess.swift`:

```swift
import Foundation

/// Outcome of the initial handshake phase (first ~5 seconds after start).
enum OpenConnectHandshake: Equatable {
    case connected           // stderr showed success keyword and pgrep confirmed
    case failed(reason: String)
}

/// Abstraction over the long-running openconnect subprocess.
/// UI / controller code only touches this protocol.
protocol OpenConnectProcessRunning: AnyObject {
    /// Start `sudo openconnect ...` and write `password\n` to its stdin.
    /// Returns after the process is spawned (not after handshake).
    func start(config: VPNConfig, password: String) throws

    /// Wait for initial handshake success or failure.
    /// Returns within `timeout` seconds; does NOT block after success.
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake

    /// Is the spawned openconnect still running?
    func isRunning() -> Bool

    /// Send SIGTERM via `sudo -n pkill -x openconnect`. Idempotent.
    func stop() throws
}

/// Production implementation — uses real Foundation.Process to run sudo openconnect.
final class OpenConnectProcess: OpenConnectProcessRunning {
    private var process: Process?
    private var stderrHandle: FileHandle?
    private var collectedStderr = Data()
    private let stderrQueue = DispatchQueue(label: "openconnect.stderr")

    private let processRunner: ProcessRunning

    init(processRunner: ProcessRunning = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    func start(config: VPNConfig, password: String) throws {
        // Clean up any prior invocation.
        try? stop()
        process = nil
        collectedStderr = Data()

        let scriptPath: String
        if config.skipDNSModification,
           let bundled = Bundle.main.path(forResource: "vpnc-script--no-dns", ofType: nil) {
            scriptPath = bundled
        } else {
            scriptPath = config.vpncScriptPath
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = [
            "-n",
            config.openconnectPath,
            "--script", scriptPath,
            "--user", config.username,
            "--passwd-on-stdin",
            "--servercert", config.serverCertPin,
            config.gateway,
        ]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = stderrPipe

        try p.run()
        stdinPipe.fileHandleForWriting.write((password + "\n").data(using: .utf8) ?? Data())
        try? stdinPipe.fileHandleForWriting.close()

        stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle?.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.stderrQueue.sync {
                self?.collectedStderr.append(chunk)
            }
        }
        self.process = p
    }

    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake {
        let successMarkers = [
            "Connected as",
            "CSTP connected",
            "Established DTLS",
            "ESP session established",
        ]
        let failureMarkers = [
            "Login failed",
            "authentication failure",
            "sudo: a password is required",
            "Certificate verification failure",
        ]

        let startTime = Date()
        let gracePeriod: TimeInterval = 1.5

        while Date().timeIntervalSince(startTime) < timeout {
            guard let p = process else {
                return .failed(reason: "openconnect process not started")
            }

            let stderrText = stderrQueue.sync {
                String(data: collectedStderr, encoding: .utf8) ?? ""
            }

            // Explicit failure keywords — return immediately.
            for marker in failureMarkers where stderrText.contains(marker) {
                let reason = mapFailureMarker(marker, fullStderr: stderrText)
                return .failed(reason: reason)
            }

            // Process already exited during handshake phase → failure.
            if !p.isRunning {
                let reason = tailOfStderr(stderrText, bytes: 200)
                return .failed(reason: reason.isEmpty ? "openconnect exited before handshake" : reason)
            }

            // Success keyword + pgrep confirmed → connected.
            let keywordHit = successMarkers.contains { stderrText.contains($0) }
            let gracePassed = Date().timeIntervalSince(startTime) >= gracePeriod
            if isRunning() && (keywordHit || gracePassed) && pgrepOpenConnect() {
                return .connected
            }

            try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
        }

        // Timeout.
        let stderrText = stderrQueue.sync {
            String(data: collectedStderr, encoding: .utf8) ?? ""
        }
        let reason = tailOfStderr(stderrText, bytes: 200)
        return .failed(reason: reason.isEmpty ? "Handshake timeout" : reason)
    }

    func isRunning() -> Bool {
        pgrepOpenConnect()
    }

    func stop() throws {
        _ = try? processRunner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/usr/bin/pkill", "-x", "openconnect"],
            timeoutSeconds: 3
        )
        process = nil
    }

    // MARK: - helpers

    private func pgrepOpenConnect() -> Bool {
        let result = try? processRunner.run(
            executable: "/usr/bin/pgrep",
            arguments: ["-x", "openconnect"],
            timeoutSeconds: 2
        )
        return result?.succeeded ?? false
    }

    private func tailOfStderr(_ text: String, bytes: Int) -> String {
        guard text.count > bytes else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let start = text.index(text.endIndex, offsetBy: -bytes)
        return String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapFailureMarker(_ marker: String, fullStderr: String) -> String {
        switch marker {
        case "Login failed", "authentication failure":
            return "Authentication failed — please check your TOTP secret or password prefix."
        case "sudo: a password is required":
            return "sudo is prompting for a password. Configure NOPASSWD in visudo."
        case "Certificate verification failure":
            return "Server certificate verification failed. The gateway cert may have rotated — update the pin in Settings → Advanced."
        default:
            return tailOfStderr(fullStderr, bytes: 200)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/Core/OpenConnectProcess.swift
git commit -m "feat: add OpenConnectProcessRunning protocol and production subprocess wrapper"
```

---

## Task 7: DependencyChecker

**Files:**
- Create: `VPNMenuBar/Dependencies/DependencyChecker.swift`
- Create: `VPNMenuBarTests/DependencyCheckerTests.swift`

- [ ] **Step 1: Write failing tests with a mock ProcessRunner**

Create `VPNMenuBarTests/DependencyCheckerTests.swift`:

```swift
import XCTest
@testable import VPNMenuBar

final class MockProcessRunner: ProcessRunning {
    /// Key: "<executable> <arg0> <arg1>..." — value: result to return.
    var responses: [String: ProcessResult] = [:]
    private(set) var calls: [String] = []

    func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key)
        if let r = responses[key] { return r }
        return ProcessResult(exitCode: 1, stdout: "", stderr: "not stubbed")
    }
}

final class DependencyCheckerTests: XCTestCase {
    func makeConfig(openconnect: String = "/opt/homebrew/bin/openconnect",
                    vpncScript: String = "/usr/local/bin/vpnc-script-test") -> VPNConfig {
        var c = VPNConfig(username: "u", passwordPrefix: "p", totpSecret: "t")
        c.openconnectPath = openconnect
        c.vpncScriptPath = vpncScript
        return c
    }

    func testAllGreenWhenEverythingPasses() throws {
        // Create a real file for vpnc-script check.
        let tmpScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpnc-\(UUID().uuidString)")
        try "#!/bin/sh\n".write(to: tmpScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpScript) }

        // Create a real openconnect stand-in file (FileManager existence check).
        let tmpOpenconnect = FileManager.default.temporaryDirectory
            .appendingPathComponent("openconnect-\(UUID().uuidString)")
        try "".write(to: tmpOpenconnect, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpOpenconnect) }

        let mock = MockProcessRunner()
        mock.responses["\(tmpOpenconnect.path) --version"] =
            ProcessResult(exitCode: 0, stdout: "OpenConnect 9.12", stderr: "")
        mock.responses["/usr/bin/sudo -n \(tmpOpenconnect.path) --version"] =
            ProcessResult(exitCode: 0, stdout: "", stderr: "")

        let cfg = makeConfig(openconnect: tmpOpenconnect.path, vpncScript: tmpScript.path)
        let checker = DependencyChecker(runner: mock, username: "ccz")
        let statuses = checker.check(config: cfg)

        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses.allSatisfy { $0.passed }, "expected all passed, got: \(statuses)")
    }

    func testOpenconnectMissingFileFails() {
        let mock = MockProcessRunner()
        let cfg = makeConfig(openconnect: "/this/does/not/exist/openconnect")
        let checker = DependencyChecker(runner: mock, username: "ccz")
        let statuses = checker.check(config: cfg)
        let openconnectStatus = statuses.first { $0.id == .openconnect }
        XCTAssertEqual(openconnectStatus?.passed, false)
        XCTAssertTrue(openconnectStatus?.fixHint.contains("brew install openconnect") ?? false)
    }

    func testSudoersFailsWhenSudoNReturnsNonZero() throws {
        let tmpOpenconnect = FileManager.default.temporaryDirectory
            .appendingPathComponent("openconnect-\(UUID().uuidString)")
        try "".write(to: tmpOpenconnect, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpOpenconnect) }

        let mock = MockProcessRunner()
        mock.responses["\(tmpOpenconnect.path) --version"] =
            ProcessResult(exitCode: 0, stdout: "ok", stderr: "")
        mock.responses["/usr/bin/sudo -n \(tmpOpenconnect.path) --version"] =
            ProcessResult(exitCode: 1, stdout: "", stderr: "sudo: a password is required")

        let cfg = makeConfig(openconnect: tmpOpenconnect.path)
        let checker = DependencyChecker(runner: mock, username: "ccz")
        let statuses = checker.check(config: cfg)
        let sudoStatus = statuses.first { $0.id == .sudoersRule }
        XCTAssertEqual(sudoStatus?.passed, false)
        XCTAssertTrue(sudoStatus?.fixHint.contains("visudo") ?? false)
        XCTAssertTrue(sudoStatus?.fixCommand?.contains("ccz ALL=(root) NOPASSWD") ?? false)
    }

    func testVpncScriptMissingFails() {
        let mock = MockProcessRunner()
        let cfg = makeConfig(vpncScript: "/nonexistent/vpnc-script")
        let checker = DependencyChecker(runner: mock, username: "ccz")
        let statuses = checker.check(config: cfg)
        XCTAssertEqual(statuses.first { $0.id == .vpncScript }?.passed, false)
    }
}
```

- [ ] **Step 2: Regenerate and run to confirm failure**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `cannot find 'DependencyChecker' in scope`.

- [ ] **Step 3: Create `DependencyChecker.swift`**

Create `VPNMenuBar/Dependencies/DependencyChecker.swift`:

```swift
import Foundation

enum DependencyID: String { case openconnect, sudoersRule, vpncScript }

struct DependencyStatus: Equatable {
    let id: DependencyID
    let passed: Bool
    let detail: String
    let fixHint: String
    let fixCommand: String?
}

final class DependencyChecker {
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
        let openconnect = checkOpenconnect(config: config)
        let sudoers = checkSudoersRule(config: config, openconnectPassed: openconnect.passed)
        let vpnc = checkVpncScript(config: config)
        return [openconnect, sudoers, vpnc]
    }

    // MARK: - individual checks

    private func checkOpenconnect(config: VPNConfig) -> DependencyStatus {
        guard fileManager.fileExists(atPath: config.openconnectPath) else {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect not found at \(config.openconnectPath)",
                fixHint: "openconnect not found. Run 'brew install openconnect' in Terminal, then verify the path in Settings → Advanced (default on Apple Silicon: /opt/homebrew/bin/openconnect).",
                fixCommand: "brew install openconnect"
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
                fixCommand: nil
            )
        } else {
            return DependencyStatus(
                id: .openconnect,
                passed: false,
                detail: "openconnect at \(config.openconnectPath) failed to run",
                fixHint: "openconnect exists but --version returned non-zero. Reinstall with 'brew reinstall openconnect'.",
                fixCommand: "brew reinstall openconnect"
            )
        }
    }

    private func checkSudoersRule(config: VPNConfig, openconnectPassed: Bool) -> DependencyStatus {
        // Skip the sudo check if openconnect itself is missing — no point in double-reporting.
        guard openconnectPassed else {
            return DependencyStatus(
                id: .sudoersRule,
                passed: false,
                detail: "Skipped (openconnect missing)",
                fixHint: "Fix the openconnect dependency above first, then recheck.",
                fixCommand: nil
            )
        }

        let result = (try? runner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", config.openconnectPath, "--version"],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")

        if result.succeeded {
            return DependencyStatus(
                id: .sudoersRule,
                passed: true,
                detail: "sudo NOPASSWD rule active",
                fixHint: "",
                fixCommand: nil
            )
        }

        let sudoersLine = "\(username) ALL=(root) NOPASSWD: \(config.openconnectPath), /usr/bin/pkill -x openconnect"
        return DependencyStatus(
            id: .sudoersRule,
            passed: false,
            detail: "sudo -n returned non-zero (NOPASSWD rule not configured)",
            fixHint:
                "This app needs to run sudo openconnect without a password prompt. " +
                "Run 'sudo visudo' and append this line at the end of the file:\n\n" +
                sudoersLine,
            fixCommand: sudoersLine
        )
    }

    private func checkVpncScript(config: VPNConfig) -> DependencyStatus {
        if fileManager.fileExists(atPath: config.vpncScriptPath) {
            return DependencyStatus(
                id: .vpncScript,
                passed: true,
                detail: "vpnc-script found at \(config.vpncScriptPath)",
                fixHint: "",
                fixCommand: nil
            )
        }
        return DependencyStatus(
            id: .vpncScript,
            passed: false,
            detail: "vpnc-script not found at \(config.vpncScriptPath)",
            fixHint:
                "vpnc-script not found. Brew upgrades change this path. " +
                "Open Settings → Advanced and update 'vpnc-script path' to " +
                "/opt/homebrew/Cellar/openconnect/<version>/.bottle/etc/vpnc/vpnc-script",
            fixCommand: nil
        )
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `Test Suite 'DependencyCheckerTests' passed`, 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add VPNMenuBar/Dependencies/DependencyChecker.swift VPNMenuBarTests/DependencyCheckerTests.swift
git commit -m "feat: add DependencyChecker with openconnect/sudoers/vpnc-script checks"
```

---

## Task 8: VPNController state machine

**Files:**
- Create: `VPNMenuBar/Core/VPNController.swift`
- Create: `VPNMenuBarTests/VPNControllerTests.swift`

- [ ] **Step 1: Write failing tests using a fake OpenConnectProcessRunning**

Create `VPNMenuBarTests/VPNControllerTests.swift`:

```swift
import XCTest
@testable import VPNMenuBar

/// Script-driven fake. Tests call `scheduleHandshake(result:)` before `connect()`.
final class FakeOpenConnectProcess: OpenConnectProcessRunning {
    var startCalled = false
    var stopCalled = false
    private var pendingHandshake: OpenConnectHandshake = .failed(reason: "not scheduled")
    private var running = false

    func scheduleHandshake(result: OpenConnectHandshake) {
        pendingHandshake = result
    }

    func simulateProcessExit() {
        running = false
    }

    func start(config: VPNConfig, password: String) throws {
        startCalled = true
        running = true
    }

    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake {
        if case .connected = pendingHandshake {
            running = true
        } else {
            running = false
        }
        return pendingHandshake
    }

    func isRunning() -> Bool { running }

    func stop() throws {
        stopCalled = true
        running = false
    }
}

/// DependencyChecker stub that returns a pre-set list of statuses.
final class StubDependencyChecker: DependencyChecker {
    var scriptedStatuses: [DependencyStatus] = []
    override func check(config: VPNConfig) -> [DependencyStatus] { scriptedStatuses }
}

@MainActor
final class VPNControllerTests: XCTestCase {

    var tempDir: URL!
    var configStore: ConfigStore!
    var fakeProcess: FakeOpenConnectProcess!
    var stubChecker: StubDependencyChecker!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VPNControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configStore = ConfigStore(baseDirectory: tempDir)
        try configStore.save(VPNConfig(username: "u", passwordPrefix: "p", totpSecret: "JBSWY3DPEHPK3PXP"))

        fakeProcess = FakeOpenConnectProcess()
        stubChecker = StubDependencyChecker()
        stubChecker.scriptedStatuses = [
            DependencyStatus(id: .openconnect, passed: true, detail: "", fixHint: "", fixCommand: nil),
            DependencyStatus(id: .sudoersRule, passed: true, detail: "", fixHint: "", fixCommand: nil),
            DependencyStatus(id: .vpncScript, passed: true, detail: "", fixHint: "", fixCommand: nil),
        ]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeController() -> VPNController {
        VPNController(
            configStore: configStore,
            dependencyChecker: stubChecker,
            openConnectProcess: fakeProcess
        )
    }

    func testConnectSuccessTransitionsToConnected() async {
        fakeProcess.scheduleHandshake(result: .connected)
        let controller = makeController()
        XCTAssertEqual(controller.state, .disconnected)

        await controller.connect()

        if case .connected = controller.state {
            XCTAssertTrue(fakeProcess.startCalled)
        } else {
            XCTFail("expected .connected, got \(controller.state)")
        }
    }

    func testConnectAuthFailureTransitionsToFailed() async {
        fakeProcess.scheduleHandshake(result: .failed(reason: "Authentication failed"))
        let controller = makeController()

        await controller.connect()

        if case .failed(let reason) = controller.state {
            XCTAssertTrue(reason.contains("Authentication failed"))
        } else {
            XCTFail("expected .failed, got \(controller.state)")
        }
    }

    func testConnectBlockedByMissingDependency() async {
        stubChecker.scriptedStatuses[1] = DependencyStatus(
            id: .sudoersRule, passed: false, detail: "", fixHint: "visudo", fixCommand: nil
        )
        let controller = makeController()

        await controller.connect()

        XCTAssertFalse(fakeProcess.startCalled)
        if case .failed(let reason) = controller.state {
            XCTAssertTrue(reason.contains("dependency") || reason.contains("Dependency"))
        } else {
            XCTFail("expected .failed, got \(controller.state)")
        }
    }

    func testDisconnectTransitionsToDisconnected() async {
        fakeProcess.scheduleHandshake(result: .connected)
        let controller = makeController()
        await controller.connect()
        XCTAssertTrue(controller.state.isConnected)

        await controller.disconnect()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertTrue(fakeProcess.stopCalled)
    }
}
```

- [ ] **Step 2: Regenerate and run to confirm failure**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `cannot find 'VPNController' in scope`.

- [ ] **Step 3: Create `VPNController.swift`**

Create `VPNMenuBar/Core/VPNController.swift`:

```swift
import Foundation
import Combine

@MainActor
final class VPNController: ObservableObject {

    @Published private(set) var state: VPNState = .disconnected
    @Published private(set) var lastDependencyStatuses: [DependencyStatus] = []

    private let configStore: ConfigStore
    private let dependencyChecker: DependencyChecker
    private let openConnectProcess: OpenConnectProcessRunning
    private let handshakeTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private var monitorTask: Task<Void, Never>?

    init(
        configStore: ConfigStore,
        dependencyChecker: DependencyChecker,
        openConnectProcess: OpenConnectProcessRunning,
        handshakeTimeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 2.0
    ) {
        self.configStore = configStore
        self.dependencyChecker = dependencyChecker
        self.openConnectProcess = openConnectProcess
        self.handshakeTimeout = handshakeTimeout
        self.pollInterval = pollInterval
    }

    // MARK: - Public API

    func connect() async {
        guard let config = (try? configStore.load()), config.isConfigured else {
            state = .failed(reason: "Setup incomplete — open Settings to finish configuration.")
            return
        }

        let statuses = dependencyChecker.check(config: config)
        lastDependencyStatuses = statuses
        if let failed = statuses.first(where: { !$0.passed }) {
            state = .failed(reason: "Dependency not ready: \(failed.detail)")
            return
        }

        state = .connecting

        let code: String
        do {
            code = try TOTPGenerator.code(secret: config.totpSecret)
        } catch {
            state = .failed(reason: "Invalid TOTP secret — please check Settings.")
            return
        }
        let password = config.passwordPrefix + code

        do {
            try openConnectProcess.start(config: config, password: password)
        } catch {
            state = .failed(reason: "Failed to start openconnect: \(error.localizedDescription)")
            return
        }

        let outcome = await openConnectProcess.waitForHandshake(timeout: handshakeTimeout)
        switch outcome {
        case .connected:
            state = .connected(since: Date())
            startMonitoring()
        case .failed(let reason):
            state = .failed(reason: reason)
        }
    }

    func disconnect() async {
        monitorTask?.cancel()
        monitorTask = nil
        do {
            try openConnectProcess.stop()
        } catch {
            // stop() is best-effort — we still want to transition to disconnected.
        }
        state = .disconnected
    }

    func reconnect() async {
        await disconnect()
        await connect()
    }

    func checkDependencies() -> [DependencyStatus] {
        guard let config = (try? configStore.load()) else { return [] }
        let statuses = dependencyChecker.check(config: config)
        lastDependencyStatuses = statuses
        return statuses
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        monitorTask?.cancel()
        let interval = pollInterval
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                let stillRunning = self.openConnectProcess.isRunning()
                await MainActor.run {
                    if !stillRunning, case .connected = self.state {
                        self.state = .disconnected
                    }
                }
                if !stillRunning { return }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests and verify they pass**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: all 4 `VPNControllerTests` pass plus previous tests still green.

- [ ] **Step 5: Commit**

```bash
git add VPNMenuBar/Core/VPNController.swift VPNMenuBarTests/VPNControllerTests.swift
git commit -m "feat: add VPNController state machine with injected dependencies"
```

---

## Task 9: StatusBarIconFactory (NSImage composition)

**Files:**
- Create: `VPNMenuBar/UI/StatusBarIconFactory.swift`

- [ ] **Step 1: Create `StatusBarIconFactory.swift`**

Create `VPNMenuBar/UI/StatusBarIconFactory.swift`:

```swift
import AppKit
import SwiftUI

/// Builds the status-bar icon for a given VPN state:
/// a template SF Symbol ("lock.shield") with a small colored dot overlay.
enum StatusBarIconFactory {
    static func image(for state: VPNState) -> NSImage {
        let baseSize = NSSize(width: 22, height: 18)
        let iconSize = NSSize(width: 16, height: 16)

        let result = NSImage(size: baseSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        // 1. Base SF Symbol (lock.shield) rendered as template so it follows menu tint.
        if let base = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "VPN") {
            base.isTemplate = true
            base.size = iconSize
            base.draw(
                in: NSRect(x: 0, y: 1, width: iconSize.width, height: iconSize.height),
                from: .zero,
                operation: .sourceOver,
                fraction: state == .disconnected ? 0.55 : 1.0
            )
        }

        // 2. Colored status dot in the top-right corner.
        let dotRect = NSRect(x: baseSize.width - 7, y: baseSize.height - 7, width: 6, height: 6)
        let path = NSBezierPath(ovalIn: dotRect)
        dotColor(for: state).setFill()
        path.fill()

        result.isTemplate = false  // dot is colored, so we can't be a pure template.
        return result
    }

    private static func dotColor(for state: VPNState) -> NSColor {
        switch state {
        case .connected:          return NSColor.systemGreen
        case .connecting:         return NSColor.systemOrange
        case .failed:             return NSColor.systemRed
        case .disconnected:       return NSColor.systemGray
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/UI/StatusBarIconFactory.swift
git commit -m "feat: add StatusBarIconFactory for SF Symbol + colored dot per state"
```

---

## Task 10: MenuContentView

**Files:**
- Create: `VPNMenuBar/UI/MenuContentView.swift`

- [ ] **Step 1: Create `MenuContentView.swift`**

Create `VPNMenuBar/UI/MenuContentView.swift`:

```swift
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var controller: VPNController
    var onOpenSettings: () -> Void
    var onCheckDependencies: () -> Void

    var body: some View {
        // Status header — disabled item, shows current state + gateway hint.
        Text(headerText)
            .disabled(true)

        Divider()

        switch controller.state {
        case .disconnected, .failed:
            Button("Connect") {
                Task { await controller.connect() }
            }
        case .connecting:
            Button("Connecting…") {}
                .disabled(true)
        case .connected:
            Button("Disconnect") {
                Task { await controller.disconnect() }
            }
            Button("Reconnect") {
                Task { await controller.reconnect() }
            }
        }

        Divider()

        Button("Open Settings…") { onOpenSettings() }
        Button("Check Dependencies…") { onCheckDependencies() }

        Divider()

        Button("Quit") {
            Task {
                await controller.disconnect()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var headerText: String {
        switch controller.state {
        case .disconnected:
            return "VPN: Disconnected"
        case .connecting:
            return "VPN: Connecting…"
        case .connected(let since):
            let elapsed = Int(Date().timeIntervalSince(since))
            let mm = elapsed / 60
            let ss = elapsed % 60
            return String(format: "VPN: Connected (%02d:%02d)", mm, ss)
        case .failed(let reason):
            // Clip long reasons for menu width.
            let clipped = reason.count > 60 ? String(reason.prefix(57)) + "…" : reason
            return "VPN: \(clipped)"
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/UI/MenuContentView.swift
git commit -m "feat: add MenuContentView with status header and action buttons"
```

---

## Task 11: SettingsView

**Files:**
- Create: `VPNMenuBar/UI/SettingsView.swift`

- [ ] **Step 1: Create `SettingsView.swift`**

Create `VPNMenuBar/UI/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore

    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")
    @State private var showAdvanced: Bool = false
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabled
    @State private var saveMessage: String?

    var body: some View {
        Form {
            Section("Required") {
                TextField("Username", text: $config.username)
                SecureField("Password prefix", text: $config.passwordPrefix)
                SecureField("TOTP secret (Base32)", text: $config.totpSecret)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("Gateway", text: $config.gateway)
                TextField("Server cert pin", text: $config.serverCertPin)
                TextField("openconnect path", text: $config.openconnectPath)
                TextField("vpnc-script path", text: $config.vpncScriptPath)
                Toggle("Skip DNS modification (use bundled vpnc-script--no-dns)",
                       isOn: $config.skipDNSModification)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LoginItemManager.setEnabled(newValue)
                    }
            }

            Section {
                HStack {
                    Button("Check Dependencies…") {
                        _ = controller.checkDependencies()
                    }
                    Spacer()
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
                if let msg = saveMessage {
                    Text(msg).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private func load() {
        if let existing = try? configStore.load() {
            config = existing
        }
    }

    private func save() {
        do {
            try configStore.save(config)
            if controller.state.isConnected {
                saveMessage = "Configuration saved. The new values will take effect on the next connection."
            } else {
                saveMessage = "Saved."
            }
        } catch {
            saveMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Build (will fail — `LoginItemManager` doesn't exist yet)**

We expect a build failure referencing `LoginItemManager`. That's fine — we'll add it in Task 14. Temporarily comment out the two lines that touch `LoginItemManager` so the project keeps building through Tasks 12–13:

Edit the `@State private var launchAtLogin` line and the `onChange` block:

```swift
    @State private var launchAtLogin: Bool = false   // TODO(Task 14): wire to LoginItemManager
```

And replace the onChange body with:

```swift
                    .onChange(of: launchAtLogin) { _ in
                        // TODO(Task 14): LoginItemManager.setEnabled(newValue)
                    }
```

- [ ] **Step 3: Build and verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VPNMenuBar/UI/SettingsView.swift
git commit -m "feat: add SettingsView with required/advanced sections"
```

---

## Task 12: OnboardingView

**Files:**
- Create: `VPNMenuBar/UI/OnboardingView.swift`

- [ ] **Step 1: Create `OnboardingView.swift`**

Create `VPNMenuBar/UI/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: VPNController
    let configStore: ConfigStore
    var onFinished: () -> Void

    @State private var step: Int = 1
    @State private var dependencyStatuses: [DependencyStatus] = []
    @State private var config: VPNConfig = VPNConfig(username: "", passwordPrefix: "", totpSecret: "")

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
        .frame(width: 480, height: 520)
        .onAppear {
            if let existing = try? configStore.load() {
                config = existing
            }
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
            ForEach(dependencyStatuses, id: \.id.rawValue) { status in
                HStack(alignment: .top) {
                    Image(systemName: status.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(status.passed ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.detail).font(.body)
                        if !status.passed {
                            Text(status.fixHint).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            Button("Recheck") {
                dependencyStatuses = controller.checkDependencies()
            }
        }
        .onAppear {
            dependencyStatuses = controller.checkDependencies()
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Credentials").font(.title2).bold()
            TextField("Username", text: $config.username)
            SecureField("Password prefix", text: $config.passwordPrefix)
            SecureField("TOTP secret (Base32)", text: $config.totpSecret)
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
            // In-line error display kept simple; user sees nothing change and can retry.
            NSLog("OnboardingView save failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/UI/OnboardingView.swift
git commit -m "feat: add OnboardingView 4-step wizard"
```

---

## Task 13: DependencyAlertView

**Files:**
- Create: `VPNMenuBar/UI/DependencyAlertView.swift`

- [ ] **Step 1: Create `DependencyAlertView.swift`**

Create `VPNMenuBar/UI/DependencyAlertView.swift`:

```swift
import SwiftUI
import AppKit

struct DependencyAlertView: View {
    @ObservedObject var controller: VPNController
    var onClose: () -> Void

    @State private var statuses: [DependencyStatus] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)
                Text("Dependencies").font(.title2).bold()
            }

            ForEach(statuses, id: \.id.rawValue) { s in
                dependencyRow(s)
            }

            Divider()

            HStack {
                Button("Recheck") {
                    statuses = controller.checkDependencies()
                }
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            statuses = controller.checkDependencies()
        }
    }

    @ViewBuilder
    private func dependencyRow(_ s: DependencyStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: s.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(s.passed ? .green : .red)
                Text(s.detail).font(.body)
            }
            if !s.passed {
                Text(s.fixHint)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cmd = s.fixCommand {
                    HStack {
                        Text(cmd)
                            .font(.system(.caption, design: .monospaced))
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)
                        Spacer()
                        Button("Copy") { copy(cmd) }
                    }
                }
            }
        }
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/UI/DependencyAlertView.swift
git commit -m "feat: add DependencyAlertView with Copy and Recheck"
```

---

## Task 14: LoginItemManager (SMAppService wrapper)

**Files:**
- Create: `VPNMenuBar/Util/LoginItemManager.swift`
- Modify: `VPNMenuBar/UI/SettingsView.swift` (restore the Task 11 TODOs)

- [ ] **Step 1: Create `LoginItemManager.swift`**

Create `VPNMenuBar/Util/LoginItemManager.swift`:

```swift
import Foundation
import ServiceManagement

enum LoginItemManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("LoginItemManager.setEnabled(\(enabled)) failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Restore the Task 11 TODOs in `SettingsView.swift`**

Change:

```swift
    @State private var launchAtLogin: Bool = false   // TODO(Task 14): wire to LoginItemManager
```

to:

```swift
    @State private var launchAtLogin: Bool = LoginItemManager.isEnabled
```

And change:

```swift
                    .onChange(of: launchAtLogin) { _ in
                        // TODO(Task 14): LoginItemManager.setEnabled(newValue)
                    }
```

to:

```swift
                    .onChange(of: launchAtLogin) { newValue in
                        LoginItemManager.setEnabled(newValue)
                    }
```

- [ ] **Step 3: Build to verify it compiles**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add VPNMenuBar/Util/LoginItemManager.swift VPNMenuBar/UI/SettingsView.swift
git commit -m "feat: add LoginItemManager via SMAppService and wire it to SettingsView"
```

---

## Task 15: Wire everything in VPNMenuBarApp + bundle resource + smoke test + README

**Files:**
- Modify: `VPNMenuBar/App/VPNMenuBarApp.swift`
- Modify: `project.yml` (bundle vpnc-script--no-dns)
- Create: `VPNMenuBar/Resources/vpnc-script--no-dns` (copy from repo root)
- Create: `README.md`

- [ ] **Step 1: Copy `vpnc-script--no-dns` into the Resources folder**

Run:
```bash
mkdir -p VPNMenuBar/Resources
cp vpnc-script--no-dns VPNMenuBar/Resources/vpnc-script--no-dns
chmod +x VPNMenuBar/Resources/vpnc-script--no-dns
```

- [ ] **Step 2: Update `project.yml` to bundle the resource**

Edit `project.yml`, replace the `VPNMenuBar` target's `sources:` block:

```yaml
  VPNMenuBar:
    type: application
    platform: macOS
    sources:
      - path: VPNMenuBar
        excludes:
          - "Resources/**"
      - path: VPNMenuBar/Resources
        buildPhase: resources
        type: folder
```

- [ ] **Step 3: Rewrite `VPNMenuBarApp.swift` to wire everything together**

Replace `VPNMenuBar/App/VPNMenuBarApp.swift` with:

```swift
import SwiftUI
import AppKit
import UserNotifications

@main
struct VPNMenuBarApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                controller: coordinator.controller,
                onOpenSettings: coordinator.openSettings,
                onCheckDependencies: coordinator.openDependencyAlert
            )
        } label: {
            Image(nsImage: StatusBarIconFactory.image(for: coordinator.controller.state))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                controller: coordinator.controller,
                configStore: coordinator.configStore
            )
        }
    }
}

/// Owns the singleton controller and manages auxiliary windows (Onboarding, DependencyAlert).
@MainActor
final class AppCoordinator: ObservableObject {
    let configStore: ConfigStore
    let dependencyChecker: DependencyChecker
    let controller: VPNController

    private var onboardingWindow: NSWindow?
    private var dependencyAlertWindow: NSWindow?

    init() {
        let store = ConfigStore()
        let checker = DependencyChecker()
        self.configStore = store
        self.dependencyChecker = checker
        self.controller = VPNController(
            configStore: store,
            dependencyChecker: checker,
            openConnectProcess: OpenConnectProcess()
        )

        requestNotificationPermission()
        showOnboardingIfNeeded()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func showOnboardingIfNeeded() {
        if !configStore.isConfigured {
            openOnboarding()
        }
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    func openOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            controller: controller,
            configStore: configStore,
            onFinished: { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Setup"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        onboardingWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openDependencyAlert() {
        if let win = dependencyAlertWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DependencyAlertView(
            controller: controller,
            onClose: { [weak self] in
                self?.dependencyAlertWindow?.close()
                self?.dependencyAlertWindow = nil
            }
        )
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Dependencies"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        dependencyAlertWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 4: Build the full project**

```bash
xcodegen generate
xcodebuild \
  -project VPNMenuBar.xcodeproj \
  -scheme VPNMenuBar \
  -destination 'platform=macOS' \
  -configuration Debug \
  build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite to make sure nothing regressed**

```bash
xcodebuild \
  -project VPNMenuBar.xcodeproj \
  -scheme VPNMenuBar \
  -destination 'platform=macOS' \
  test 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`, all tests from Tasks 1/2/3/7/8 passing.

- [ ] **Step 6: Manual smoke test — launch the app from the command line**

First, locate the built app and launch it:

```bash
APP_PATH=$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)
echo "App at: $APP_PATH"
open "$APP_PATH"
```

Expected checklist (do each manually):

1. Shield icon with gray dot appears in the menu bar.
2. Onboarding window opens automatically (config.json absent on first run).
3. Step 1 → Next works.
4. Step 2 shows three dependency rows. If anything is red, fix on your machine (brew, visudo) and click Recheck.
5. Step 3 accepts credentials; Save & Continue is disabled until all three are non-empty.
6. Step 4 closes the wizard.
7. Click the shield icon → menu shows "Connect".
8. Click Connect. Within ~5 seconds the menu item becomes "Disconnect" and the dot turns green. A real openconnect process should be running (`pgrep -x openconnect`).
9. Click Disconnect. The process goes away and the dot turns gray.
10. Click Open Settings… → a SwiftUI Settings window appears with the values you entered; the DisclosureGroup can be expanded.
11. Toggle "Launch at login" on then off. No error dialogs.
12. Right-click the app icon in `/Applications` (if you copied it there) → Open, once, to approve the unsigned app; from then on login-at-start works.

If any step fails, fix in place and re-run the build/smoke sequence.

- [ ] **Step 7: Write `README.md`**

Create `/Users/ccz/Desktop/r100/vpn/README.md`:

```markdown
# VPN MenuBar

A macOS 13+ status-bar app that replaces the `vpn.py` script — connects to the corporate VPN via `openconnect` with a TOTP-generated one-time code.

## Prerequisites

1. **Homebrew openconnect**
   ```bash
   brew install openconnect
   ```
2. **Passwordless sudo rule** — run `sudo visudo` and append (replace `<user>` with your macOS username):
   ```
   <user> ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -x openconnect
   ```
3. **XcodeGen** (build-time only)
   ```bash
   brew install xcodegen
   ```

## Build

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -configuration Release -destination 'platform=macOS' build
```

Copy the resulting `VPNMenuBar.app` from the `build/` or `DerivedData` directory into `/Applications`.

## First launch

The app is ad-hoc signed and unnotarized, so macOS will refuse to open it the first time. Go to **System Settings → Privacy & Security → Open Anyway**, then launch again. After that the login item works normally.

On first launch the Onboarding window collects three required fields — username, password prefix, and TOTP secret (Base32). All other fields (gateway, cert pin, openconnect path, vpnc-script path) are editable in Settings → Advanced.

## Config file

Location: `~/Library/Application Support/com.example.vpnmenubar/config.json`
Permissions: `0600`
Contents: plain JSON. Back it up if you rely on it.
```

- [ ] **Step 8: Commit**

```bash
git add VPNMenuBar/App/VPNMenuBarApp.swift project.yml VPNMenuBar/Resources/vpnc-script--no-dns README.md
git commit -m "feat: wire MenuBarExtra, Settings, Onboarding, and DependencyAlert windows"
```

---

## Self-Review

### Spec coverage check

| Spec section | Plan task |
|---|---|
| §3 Architecture & modules | Tasks 0–14 (one module per task) |
| §3.1 Dependency direction | Enforced by task order (Core before UI) |
| §3.2 OpenConnectProcessRunning protocol | Task 6 |
| §4.1 VPNState enum | Task 4 |
| §4.2 connect() sequence | Task 8 (`VPNController.connect()`) + Task 6 (`OpenConnectProcess.waitForHandshake`) |
| §4.3 disconnect via pkill | Task 6 (`OpenConnectProcess.stop`) |
| §4.4 reconnect() | Task 8 (`VPNController.reconnect()`) |
| §4.5 Authentication failure detection | Task 6 (`mapFailureMarker`) |
| §5.1 VPNConfig structure | Task 1 |
| §5.2 ConfigStore (0600 + atomic + broken backup) | Task 2 |
| §5.3 First-launch Onboarding flow | Task 12 |
| §5.4 Settings panel layout | Task 11 + Task 14 |
| §6.1 DependencyStatus struct | Task 7 |
| §6.2 Three dependency checks | Task 7 |
| §6.3 Triggers (onboarding/pre-connect/manual) | Task 8 (VPNController pre-connect) + Task 12 (onboarding) + Task 10 (menu item) |
| §6.4 DependencyAlertView | Task 13 |
| §7 Error handling | Task 8 (controller) + Task 6 (process) + Task 2 (config broken backup) |
| §8 Test strategy | Tests in Tasks 1/2/3/7/8; smoke in Task 15 |
| §9 Packaging (ad-hoc, sandbox off, LSUIElement, SMAppService) | Task 0 (project.yml) + Task 14 (LoginItemManager) + Task 15 (wiring) |
| Bundled `vpnc-script--no-dns` resource | Task 15 |

No gaps found.

### Placeholder scan

- No "TBD"/"TODO"/"implement later" in final tasks. (Task 11's TODO is explicitly resolved in Task 14.)
- All test steps include actual test code.
- All code steps include complete code blocks.
- All command steps include exact commands and expected output.

### Type consistency

- `OpenConnectProcessRunning` signature matches across Tasks 6, 8, and VPNControllerTests (Task 8).
- `VPNConfig` field names used consistently across Tasks 1, 2, 6, 7, 8, 11, 12, 15.
- `DependencyStatus.id`/`passed`/`detail`/`fixHint`/`fixCommand` used consistently in Tasks 7, 12, 13.
- `VPNState` cases match across all tasks that reference them.

All good.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-06-macos-vpn-menubar-app.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best isolation, least context bloat in this session.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
