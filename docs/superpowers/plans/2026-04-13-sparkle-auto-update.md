# Sparkle Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Sparkle 2 for in-app auto-update backed by GitHub Releases, with EdDSA signature verification.

**Architecture:** Sparkle 2 added via SPM in `project.yml`. `AppCoordinator` owns a `SPUStandardUpdaterController`. Menu adds "Check for Updates". `appcast.xml` at repo root points to GitHub Release assets.

**Tech Stack:** Sparkle 2 (SPM), XcodeGen, EdDSA (ed25519)

---

### Task 1: Add Sparkle SPM dependency to project.yml

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add Sparkle package and target dependency to project.yml**

Add a top-level `packages` block and a `dependencies` entry under the `VPNMenuBar` target. Also add the three Info.plist keys Sparkle needs.

Edit `project.yml` to add `packages` block after `settings`:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"
```

Edit the `VPNMenuBar` target to add `dependencies` after `info`:

```yaml
    dependencies:
      - package: Sparkle
        product: Sparkle
```

Edit the `info.properties` section to add three Sparkle keys:

```yaml
        SUFeedURL: "https://raw.githubusercontent.com/CoderZCC/VPNMenuBar/main/appcast.xml"
        SUPublicEDKey: "PLACEHOLDER_WILL_BE_REPLACED_AFTER_KEY_GENERATION"
        SUEnableAutomaticChecks: true
```

The full `project.yml` after edits should look like:

```yaml
name: VPNMenuBar
options:
  bundleIdPrefix: com.example
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true

packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: "2.6.0"

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
        excludes:
          - "Resources/**"
      - path: VPNMenuBar/Resources/vpnc-script--no-dns
        buildPhase: resources
    info:
      path: VPNMenuBar/Info.plist
      properties:
        CFBundleName: VPNMenuBar
        CFBundleDisplayName: VPN MenuBar
        CFBundleShortVersionString: "0.2.0"
        CFBundleVersion: "2"
        LSMinimumSystemVersion: "13.0"
        LSUIElement: true
        NSUserNotificationAlertStyle: alert
        NSHumanReadableCopyright: "Personal use only"
        SUFeedURL: "https://raw.githubusercontent.com/CoderZCC/VPNMenuBar/main/appcast.xml"
        SUPublicEDKey: "PLACEHOLDER_WILL_BE_REPLACED_AFTER_KEY_GENERATION"
        SUEnableAutomaticChecks: true
    dependencies:
      - package: Sparkle
        product: Sparkle
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.vpnmenubar
        INFOPLIST_FILE: VPNMenuBar/Info.plist
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon

schemes:
  VPNMenuBar:
    build:
      targets:
        VPNMenuBar: all
    run:
      config: Debug
```

Note: `CFBundleShortVersionString` bumped to `"0.2.0"` and `CFBundleVersion` to `"2"` for this release.

- [ ] **Step 2: Regenerate Xcode project and verify Sparkle resolves**

Run:
```bash
cd /Users/ccz/Desktop/ccz/VPNMenuBar
xcodegen generate
```
Expected: `Generated VPNMenuBar.xcodeproj` with no errors.

Then resolve SPM packages:
```bash
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -resolvePackageDependencies
```
Expected: Sparkle package resolved successfully.

- [ ] **Step 3: Verify it compiles**

Run:
```bash
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "feat: add Sparkle 2 SPM dependency and bump version to 0.2.0"
```

---

### Task 2: Wire up SPUStandardUpdaterController in AppCoordinator

**Files:**
- Modify: `VPNMenuBar/App/VPNMenuBarApp.swift`

- [ ] **Step 1: Add Sparkle import and updater controller to AppCoordinator**

At the top of `VPNMenuBarApp.swift`, add import:

```swift
import Sparkle
```

In `AppCoordinator`, add a stored property after `private var cancellables`:

```swift
    let updaterController: SPUStandardUpdaterController
```

In `AppCoordinator.init()`, initialize it **before** `Self.shared = self`. Insert after `self.controller = VPNController(...)`:

```swift
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
```

The `startingUpdater: true` parameter tells Sparkle to begin its scheduled update checks immediately.

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add VPNMenuBar/App/VPNMenuBarApp.swift
git commit -m "feat: initialize Sparkle updater controller in AppCoordinator"
```

---

### Task 3: Add "Check for Updates" menu item

**Files:**
- Modify: `VPNMenuBar/App/VPNMenuBarApp.swift` (pass updaterController to MenuContentView)
- Modify: `VPNMenuBar/UI/MenuContentView.swift` (accept updaterController, add button)

- [ ] **Step 1: Update MenuContentView to accept updater and show button**

In `MenuContentView.swift`, add import at the top:

```swift
import Sparkle
```

Add a new property in `MenuContentView`:

```swift
    let updaterController: SPUStandardUpdaterController
```

Add a "Check for Updates…" button in the menu body. Place it after the `Button("Check Dependencies…")` block, before the final `Divider()`:

```swift
        Button("Check for Updates…") {
            updaterController.checkForUpdates(nil)
        }
```

The full body should read (relevant section):

```swift
        Button("Check Dependencies…") { onCheckDependencies() }

        Button("Check for Updates…") {
            updaterController.checkForUpdates(nil)
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
```

- [ ] **Step 2: Pass updaterController from VPNMenuBarApp.body**

In `VPNMenuBarApp.swift`, update the `MenuContentView` initializer call inside `MenuBarExtra` to pass the updater:

```swift
            MenuContentView(
                controller: coordinator.controller,
                onOpenSettings: coordinator.openSettings,
                onCheckDependencies: coordinator.openDependencyAlert,
                updaterController: coordinator.updaterController
            )
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add VPNMenuBar/UI/MenuContentView.swift VPNMenuBar/App/VPNMenuBarApp.swift
git commit -m "feat: add Check for Updates menu item powered by Sparkle"
```

---

### Task 4: Generate EdDSA keys and update SUPublicEDKey

**Files:**
- Modify: `project.yml` (replace placeholder SUPublicEDKey with real public key)

This task requires manual interaction because the private key is stored in the user's Keychain.

- [ ] **Step 1: Locate Sparkle's generate_keys tool**

After SPM resolves Sparkle, the `generate_keys` binary is available in the Sparkle build artifacts. Find it:

```bash
find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f 2>/dev/null | head -3
```

If not found in DerivedData, download from Sparkle's GitHub releases:

```bash
# Alternative: use the generate_keys from Sparkle's downloaded package
SPARKLE_CACHE=$(find ~/Library/Caches/org.swift.swiftpm -path "*/Sparkle-*/bin/generate_keys" 2>/dev/null | head -1)
echo "$SPARKLE_CACHE"
```

If neither path works, build and extract manually:
```bash
cd /tmp
curl -L -o Sparkle-2.6.0.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.6.0/Sparkle-2.6.0.tar.xz
tar xf Sparkle-2.6.0.tar.xz
# generate_keys is at /tmp/bin/generate_keys
```

- [ ] **Step 2: Generate the EdDSA key pair**

Run:
```bash
/path/to/generate_keys
```

Output will be something like:
```
A]  key has been generated and saved in the Keychain.
    Add the `SUPublicEDKey` key to your Info.plist:

    <key>SUPublicEDKey</key>
    <string>ACTUAL_BASE64_PUBLIC_KEY_HERE</string>
```

Copy the base64 public key string.

- [ ] **Step 3: Update SUPublicEDKey in project.yml**

Replace the placeholder in `project.yml`:

```yaml
        SUPublicEDKey: "ACTUAL_BASE64_PUBLIC_KEY_HERE"
```

- [ ] **Step 4: Regenerate and verify**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "feat: add EdDSA public key for Sparkle update verification"
```

---

### Task 5: Create initial appcast.xml

**Files:**
- Create: `appcast.xml` (repo root)

- [ ] **Step 1: Build a Release binary and create the zip**

```bash
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -destination 'platform=macOS' -configuration Release clean build

APP_SRC="$(xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/CODESIGNING_FOLDER_PATH/ {print $2}' | head -1)"
cp -R "$APP_SRC" ./VPNMenuBar.app
ditto -c -k --keepParent ./VPNMenuBar.app ./VPNMenuBar-0.2.0.zip
```

- [ ] **Step 2: Sign the zip with Sparkle's sign_update tool**

Locate `sign_update`:
```bash
find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -type f 2>/dev/null | head -1
# or from the downloaded Sparkle: /tmp/bin/sign_update
```

Sign:
```bash
/path/to/sign_update VPNMenuBar-0.2.0.zip
```

Output example:
```
sparkle:edSignature="BASE64_SIGNATURE" length="12345678"
```

Note the `edSignature` and `length` values.

- [ ] **Step 3: Create appcast.xml**

Create `appcast.xml` at the repo root with the signature and length from step 2:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>VPN MenuBar</title>
    <link>https://github.com/CoderZCC/VPNMenuBar</link>
    <description>VPN MenuBar update feed</description>
    <language>en</language>
    <item>
      <title>Version 0.2.0</title>
      <sparkle:version>2</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
        <ul>
          <li>Added auto-update via Sparkle — future updates install with one click</li>
          <li>Added "Check for Updates" menu item</li>
        </ul>
      ]]></description>
      <pubDate>Sun, 13 Apr 2026 00:00:00 +0800</pubDate>
      <enclosure
        url="https://github.com/CoderZCC/VPNMenuBar/releases/download/v0.2.0/VPNMenuBar-0.2.0.zip"
        type="application/octet-stream"
        sparkle:edSignature="BASE64_SIGNATURE_FROM_STEP_2"
        length="FILE_LENGTH_FROM_STEP_2"
      />
    </item>
  </channel>
</rss>
```

Replace `BASE64_SIGNATURE_FROM_STEP_2` and `FILE_LENGTH_FROM_STEP_2` with the actual values from step 2.

- [ ] **Step 4: Commit**

```bash
git add appcast.xml VPNMenuBar.app
git commit -m "feat: add initial appcast.xml and rebuild app with Sparkle support"
```

---

### Task 6: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `INSTALL.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README.md install section**

Add a new "Option C — download from GitHub Releases" section after Option B, and add an "Auto-Update" bullet to the Features list.

Add to Features list after the "Status-bar agent" bullet:

```markdown
- **Auto-update** — checks GitHub Releases for new versions via [Sparkle](https://sparkle-project.org/). One-click update from the menu bar
```

Add after the "Option B — build from source" section:

```markdown
### Option C — download from GitHub Releases

Download the latest `VPNMenuBar-x.y.z.zip` from the [Releases](https://github.com/CoderZCC/VPNMenuBar/releases/latest) page:

1. Unzip → drag `VPNMenuBar.app` to `/Applications`
2. `xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app`
3. Open the app — subsequent updates will be delivered automatically via the menu bar
```

- [ ] **Step 2: Update INSTALL.md**

Add a section after "快速安装（推荐）" and before "手动安装步骤":

```markdown
## 从 GitHub Releases 下载（最简单）

不需要 git，直接从 Release 页面下载最新版：

1. 打开 [最新 Release](https://github.com/CoderZCC/VPNMenuBar/releases/latest)，下载 `VPNMenuBar-x.y.z.zip`
2. 解压后把 `VPNMenuBar.app` 拖到 `/Applications`
3. 终端执行 `xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app`（或者右键 → 打开 → 打开）
4. 启动后走 Onboarding 向导

之后有新版本时，app 会**自动提示更新**，点"安装更新"即可，不用再手动下载。也可以随时从状态栏菜单点 **Check for Updates…** 手动检查。
```

- [ ] **Step 3: Update CLAUDE.md distribution section**

In the "Distribution" section of `CLAUDE.md`, add a note about Sparkle and appcast.xml. After the existing bullet 3 (`install-deps.sh`), add:

```markdown
4. **`appcast.xml`** — Sparkle appcast feed at repo root. Each release adds a new `<item>` with the version, EdDSA signature, file size, and GitHub Release download URL. Sparkle checks this file periodically to discover updates. Updated manually as part of the release workflow.
```

Also add to the "Build, run, ship" section, after the existing release build recipe:

```markdown
**Signing for Sparkle** (after creating the zip):
```sh
# sign_update is from Sparkle's tools (find it in DerivedData or download from Sparkle releases)
/path/to/sign_update ./VPNMenuBar-X.Y.Z.zip
# Copy the edSignature and length into appcast.xml's new <item>
```
```

- [ ] **Step 4: Commit**

```bash
git add README.md INSTALL.md CLAUDE.md
git commit -m "docs: update install instructions for Sparkle auto-update and GitHub Releases"
```

---

### Task 7: Tag, push, and create GitHub Release

- [ ] **Step 1: Tag the release**

```bash
git tag v0.2.0
git push origin main --tags
```

- [ ] **Step 2: Create GitHub Release with the zip**

```bash
gh release create v0.2.0 VPNMenuBar-0.2.0.zip \
  --title "v0.2.0" \
  --notes "$(cat <<'EOF'
## What's New

- **Auto-update via Sparkle** — the app now checks for updates automatically and installs them with one click from the menu bar
- **Check for Updates menu item** — manually trigger an update check anytime

## Install

Download `VPNMenuBar-0.2.0.zip`, unzip, drag to `/Applications`, then run:
```
xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app
```

See [INSTALL.md](https://github.com/CoderZCC/VPNMenuBar/blob/main/INSTALL.md) for the full walkthrough.
EOF
)"
```

- [ ] **Step 3: Verify the release asset URL works**

```bash
gh release view v0.2.0 --json assets --jq '.assets[0].url'
```

Expected: a URL like `https://github.com/CoderZCC/VPNMenuBar/releases/download/v0.2.0/VPNMenuBar-0.2.0.zip`

- [ ] **Step 4: Clean up the local zip**

```bash
rm VPNMenuBar-0.2.0.zip
```
