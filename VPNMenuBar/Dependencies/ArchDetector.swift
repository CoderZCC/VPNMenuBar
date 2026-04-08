import Foundation

enum CPUArchitecture: Equatable {
    case appleSilicon
    case intel
}

struct ArchPaths: Equatable {
    let brew: String
    let openconnect: String
    let vpncScript: String
}

/// Maps the host CPU architecture to the canonical Homebrew install prefix
/// (`/opt/homebrew` on Apple Silicon, `/usr/local` on Intel) and the three
/// dependency paths the app cares about. Used by `VPNConfig` defaults and
/// `DependencyChecker` so Intel users get the right paths without manually
/// editing Settings → Advanced.
enum ArchDetector {
    static var current: CPUArchitecture {
        var info = utsname()
        uname(&info)
        // Copy the fixed-size C array out of `info` first to avoid Swift's
        // exclusive-access warning when passing &info.machine to withUnsafePointer
        // while `info` is itself a var.
        var machineArray = info.machine
        let capacity = MemoryLayout.size(ofValue: machineArray)
        let machine: String = withUnsafePointer(to: &machineArray) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        return machine == "arm64" ? .appleSilicon : .intel
    }

    static var defaultPaths: ArchPaths {
        switch current {
        case .appleSilicon:
            return ArchPaths(
                brew: "/opt/homebrew/bin/brew",
                openconnect: "/opt/homebrew/bin/openconnect",
                vpncScript: "/opt/homebrew/etc/vpnc/vpnc-script"
            )
        case .intel:
            return ArchPaths(
                brew: "/usr/local/bin/brew",
                openconnect: "/usr/local/bin/openconnect",
                vpncScript: "/usr/local/etc/vpnc/vpnc-script"
            )
        }
    }
}
