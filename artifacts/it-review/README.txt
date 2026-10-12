VPNMenuBar 0.2.29 - IT review build

Source branch: codex/vpn-security-bundled-runtime
Source commit: 54b529d9b126b7d7f7ffeadd79cba4d460ece740
Apple Silicon; built with macOS 13.0 minimum deployment target.
Intel is not supported by this package.
Fixes periodic disconnects caused by the VPN session sharing the authorization helper's process group.
Fixes reconnect failures after a network switch left a stale host route to the VPN gateway.
Build and security tests passed on macOS 26; actual macOS 13/14/15 testing remains pending.
Ad-hoc signed with Hardened Runtime; not Developer ID signed or notarized.
Administrator authorization is required to connect.
Credentials are encrypted locally; the key is stored on the same device.
No personal VPN configuration or credentials are included.
For IT evaluation only; this is not an approved production release.
Follow your organization's software approval policy before running.
