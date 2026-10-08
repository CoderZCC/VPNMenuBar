import Foundation
import CryptoKit

enum ManagedRuntime {
    static let directory = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("BundledRuntime").path
    static let openconnect = directory + "/openconnect"
    static let script = directory + "/vpnc-script--no-dns"
    static let scriptSHA256 = "2fa3937eaa9fbccd964ed2c47bd70a6dc99f2dba6289e122bc884edd4e992fa6"

    static func validateConfiguration(_ config: VPNConfig) throws {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(BundledRuntimeFiles.minimumOS) else {
            throw DependencyInstallError.unsupported(reason: "This bundled VPN engine requires macOS \(BundledRuntimeFiles.minimumOS.majorVersion). Use a build supporting this Mac's system version.")
        }
        guard config.skipDNSModification else {
            throw DependencyInstallError.unsupported(reason: "This version requires the bundled no-DNS script. Enable the no-DNS setting.")
        }
        guard !config.gateway.hasPrefix("-"), !config.gateway.contains("\n"),
              !config.gateway.contains("\0"), !config.username.contains("\0"),
              !config.serverCertPin.contains("\0"), !(config.effectiveUserAgent?.contains("\0") ?? false) else {
            throw DependencyInstallError.unsupported(reason: "Invalid connection settings.")
        }
    }

    static func scriptMatches(_ data: Data) -> Bool {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == scriptSHA256
    }

    // Hashes are compiled into the application; no user-supplied manifest is trusted.
    static func checks(directory: String) -> String {
        let q = PrivilegedCommand.quote
        return BundledRuntimeFiles.hashes.sorted { $0.key < $1.key }.map { name, digest in
            let file = directory + "/" + name
            return "[ -f \(q(file)) ] && [ ! -L \(q(file)) ] && [ -x \(q(file)) ] || exit 46\n"
                + "[ \"$(/usr/bin/shasum -a 256 \(q(file)) | /usr/bin/awk '{print $1}')\" = \(q(digest)) ] || exit 47"
        }.joined(separator: "\n")
    }

    static var validationCommand: String {
        "set -eu\n" + checks(directory: directory)
    }

    /// Copy into a private root-owned session before checking or executing any bytes.
    static var stagingCommand: String {
        let q = PrivilegedCommand.quote
        var lines = ["/bin/mkdir -m 700 \"$session/runtime\""]
        for (name, digest) in BundledRuntimeFiles.hashes.sorted(by: { $0.key < $1.key }) {
            lines += [
                "/bin/cp -P \(q(directory + "/" + name)) \"$session/runtime/\(name)\"",
                "[ -f \"$session/runtime/\(name)\" ] && [ ! -L \"$session/runtime/\(name)\" ] || exit 46",
                "[ \"$(/usr/bin/shasum -a 256 \"$session/runtime/\(name)\" | /usr/bin/awk '{print $1}')\" = \(q(digest)) ] || exit 47",
                "/bin/chmod 500 \"$session/runtime/\(name)\""
            ]
        }
        return lines.joined(separator: "\n")
    }
}
