# VPN MenuBar

A macOS 13+ status-bar app that wraps OpenConnect for Cisco AnyConnect-compatible VPNs, generates the TOTP one-time code, and lives quietly in your menu bar. Universal Binary, ad-hoc signed, no Developer ID required.

> ⚠️ **This is a generic OpenConnect front-end.** The default `gateway` (`vpn.example.com`) and `serverCertPin` baked into `VPNConfig.swift` are **placeholders**. You provide your own VPN's hostname, certificate pin, and TOTP secret during the Onboarding wizard (or later in Settings → Advanced).

## Features

- **One-click in-app dependency installer** — the Onboarding wizard's Dependency Check shows a **Fix** button next to every red item:
  - **Install Homebrew** — opens Terminal with the official installer pre-typed
  - **Install openconnect** — runs `brew install openconnect` inside the app, with live progress
  - **Configure sudoers NOPASSWD rule** — one TouchID via macOS authorization writes the rule to `/etc/sudoers.d/`
  - **Reset arch-mismatched vpnc-script path** — auto-corrects when an Intel default is loaded on Apple Silicon (or vice versa)
- **Architecture-aware** — Universal Binary; auto-detects Apple Silicon vs Intel and uses the right Homebrew prefix (`/opt/homebrew` vs `/usr/local`)
- **TOTP built in** — RFC 6238 HMAC-SHA1 via CryptoKit, with its own Base32 decoder. Optional QR-code import from a screenshot file
- **Auto-reconnect on network change** — drops the VPN cleanly when WiFi disconnects, reconnects automatically when it comes back (only if you connected manually — failed connects don't loop-retry)
- **Stale host-route cleanup** — scrubs leftover routes from the previous WiFi gateway before each connect, fixing the "Failed to connect after WiFi switch" symptom
- **Status-bar agent** — `LSUIElement`, no Dock icon, no notification spam
- **Auto-update** — checks GitHub Releases for new versions via [Sparkle](https://sparkle-project.org/). One-click update from the menu bar

## Install

### Option A — use the prebuilt .app

A ready-to-run `VPNMenuBar.app` is committed in this repo (Universal Binary, ad-hoc signed):

```bash
git clone https://github.com/CoderZCC/VPNMenuBar.git
cp -R VPNMenuBar/VPNMenuBar.app /Applications/
xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app
open /Applications/VPNMenuBar.app
```

### Option B — build from source

```bash
brew install xcodegen
git clone https://github.com/CoderZCC/VPNMenuBar.git
cd VPNMenuBar
xcodegen generate
xcodebuild -project VPNMenuBar.xcodeproj -scheme VPNMenuBar \
  -configuration Release -destination 'platform=macOS' build
# The built .app is under ~/Library/Developer/Xcode/DerivedData/...
# See CLAUDE.md "Build, run, ship" for the full distribution recipe.
```

### Option C — download from GitHub Releases

Download the latest `VPNMenuBar-x.y.z.zip` from the [Releases](https://github.com/CoderZCC/VPNMenuBar/releases/latest) page:

1. Unzip → drag `VPNMenuBar.app` to `/Applications`
2. `xattr -dr com.apple.quarantine /Applications/VPNMenuBar.app`
3. Open the app — subsequent updates will be delivered automatically via the menu bar

## First launch

Right-click the app in Finder → **Open** → **Open** in the Gatekeeper warning. After that, normal launches work and the login-item registration happens automatically.

The Onboarding wizard walks you through:

1. **Welcome**
2. **Dependency Check** — Homebrew, openconnect, sudoers rule, vpnc-script. Click **Fix** on any red row to auto-install
3. **Credentials** — username, password prefix (from your VPN admin), TOTP secret (Base32 — optional QR-image import button)
4. **Done**

For the detailed walkthrough including how to extract a TOTP Base32 secret from a QR code image, see **[INSTALL.md](INSTALL.md)** (中文).

## Sudoers rule

If you skip the in-app fix and configure sudo manually, the NOPASSWD rule needs three commands. Run `sudo visudo` and append (replace `<your-user>` with your macOS username):

**Apple Silicon**:
```
<your-user> ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -x openconnect, /sbin/route
```

**Intel**:
```
<your-user> ALL=(root) NOPASSWD: /usr/local/bin/openconnect, /usr/bin/pkill -x openconnect, /sbin/route
```

The third entry (`/sbin/route`) lets the app clean stale host routes after a WiFi switch — without it you'll see "Failed to connect" errors after roaming networks.

## Configuration file

Stored at `~/Library/Application Support/com.example.vpnmenubar/config.json` with `0600` permissions. Plain JSON; contains your username, password prefix, TOTP Base32 secret, gateway, cert pin, and openconnect/vpnc-script paths.

⚠️ **Don't commit `config.json` to git or share it** — the TOTP secret is the seed for your one-time codes and is account-specific.

## Architecture

Single-target SwiftUI app with a strict one-way dependency graph:

```
UI → Core → Config / Dependencies
        ↘ Util
```

`VPNController` is the `@MainActor ObservableObject` state machine; all UI binds to its `@Published state`. Subprocess management is abstracted behind `OpenConnectProcessRunning` so the long-running `sudo openconnect` wrapper is testable in isolation.

See [**CLAUDE.md**](CLAUDE.md) for the full architecture write-up, state machine details, sudoers rationale, quirks list, and distribution recipe.

## Issues & contributions

Open issues or pull requests at <https://github.com/CoderZCC/VPNMenuBar>.
