import Foundation
import Darwin

@main
struct SecurityHardeningTests {
    static func require(_ condition: @autoclosure () -> Bool, _ reason: String) {
        precondition(condition(), reason)
    }
    static func mustFail(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }
    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let script = try Data(contentsOf: URL(fileURLWithPath: "VPNMenuBar/Resources/vpnc-script--no-dns"))
        require(ManagedRuntime.scriptMatches(script), "Pinned script digest")
        require(!ManagedRuntime.scriptMatches(script + Data("changed".utf8)), "Modified script rejected")
        var config = VPNConfig(username: "fixture", passwordPrefix: "never-in-command", totpSecret: "never-in-command-either")
        config.gateway = "vpn.example.com"
        config.serverCertPin = "fixture-pin"
        try ManagedRuntime.validateConfiguration(config)
        require(config.effectiveUserAgent == nil, "Native UA is the default")
        var untrusted = config
        untrusted.openconnectPath = "/opt/homebrew/bin/openconnect"
        try ManagedRuntime.validateConfiguration(untrusted)
        untrusted = config
        untrusted.vpncScriptPath = "/tmp/script"
        try ManagedRuntime.validateConfiguration(untrusted)
        untrusted = config
        untrusted.skipDNSModification = false
        mustFail { try ManagedRuntime.validateConfiguration(untrusted) }
        print("PASS: legacy paths ignored in favor of bundled runtime, frozen script hash, native UA")

        let command = OpenConnectProcess.launchCommand(config: config, uid: getuid())
        require(!command.contains(config.passwordPrefix) && !command.contains(config.totpSecret), "Secrets must stay out of authorization/argv")
        require(!command.contains("'--useragent'") && !command.contains("'-v'"), "No UA spoofing or HTTP tracing by default")
        require(command.contains("GNUTLS_SYSTEM_PRIORITY_FILE=/dev/null P11_KIT_NO_USER_CONFIG=1"), "Authorized TLS configuration is isolated")
        require(!command.contains("pkill") && !command.contains("/sbin/route"), "No global process kill or route deletion")
        require(OpenConnectProcess.failureReason("Authorization: secret Cookie: secret") == nil, "Unknown output must not be exposed")
        let reason = OpenConnectProcess.failureReason("Login failed token=secret") ?? ""
        require(!reason.contains("secret"), "Classified errors do not echo server output")
        require(!OpenConnectProcess.isSessionPath("/var/run/vpnmenubar.x/../../etc"), "Session traversal rejected")
        require(OpenConnectProcess.exitDiagnostic("VPNMB_SUPERVISOR_TERM\nUser cancelled (SIGINT/SIGTERM); exiting.", status: nil).contains("supervisor_term,signal_cancelled"), "Supervisor signal is distinct from child signal")
        require(OpenConnectProcess.exitDiagnostic("VPNMB_CONTROL_CLOSED", status: "0").contains("control_closed"), "Client control closure has distinct evidence")
        let ended = OpenConnectProcess.exitDiagnostic("Session terminated by server; exiting. Cookie: secret", status: "1\n")
        require(ended.contains("exit=1") && ended.contains("server_terminated") && !ended.contains("secret"), "Server termination is classified without raw output")
        let rejected = OpenConnectProcess.exitDiagnostic("Cookie was rejected by server; exiting.", status: "2")
        require(rejected.contains("cookie_rejected") && rejected.contains("exit=2"), "Expired/rejected session cookie is distinguishable")
        let network = OpenConnectProcess.exitDiagnostic("CSTP Dead Peer Detection detected dead peer!\nReconnect failed", status: "1")
        require(network.contains("dead_peer") && network.contains("reconnect_failed"), "Network evidence is retained")
        for status in ["secret", "999", "1\nsecret", "-1"] {
            let safe = OpenConnectProcess.exitDiagnostic("Authorization: secret", status: status)
            require(safe == "VPN process ended: exit=unavailable events=unclassified", "Invalid diagnostics cannot expose data")
        }
        print("PASS: no secret argv, no global kill/route command, bounded diagnostic classification")

        // Fixtures are real `route -n get` shapes from a Mac that switched subnets mid-session.
        let staleGatewayRoute = "   route to: 188.116.30.172\ndestination: 188.116.30.172\n    gateway: 10.66.33.254\n  interface: en0\n      flags: <UP,GATEWAY,HOST,DONE,STATIC>\n"
        let defaultRoute = "   route to: 188.116.30.172\ndestination: default\n       mask: default\n    gateway: 10.66.17.254\n  interface: en0\n"
        let onLinkHop = "   route to: 10.66.17.254\ndestination: 10.66.17.254\n  interface: en0\n      flags: <UP,HOST,DONE,LLINFO,WASCLONED,IFSCOPE,IFREF,ROUTER>\n"
        let offLinkHop = "   route to: 10.66.33.254\ndestination: default\n       mask: default\n    gateway: 10.66.17.254\n  interface: en0\n"
        let table = """
        Destination        Gateway            Flags               Netif Expire
        default            10.66.17.254       UGScg                 en0
        10.66.17/24        link#14            UCS                   en0      !
        10.66.17.254       f0:33:e5:a0:3:f3   UHLWIir               en0   1181
        77.242.243.181     10.66.34.254       UGHS                  en0
        188.116.30.172     10.66.33.254       UGHS                  en0
        203.0.113.9        10.66.35.254       UGHS                  en0
        """
        let gatewayIPs = OpenConnectProcess.resolvedIPv4Addresses("name: vpn.example.com\nip_address: 188.116.30.172\nip_address: 77.242.243.181\n\nname: vpn.example.com\nipv6_address: 2001:db8::1\n")
        require(gatewayIPs == ["188.116.30.172", "77.242.243.181"], "Every round-robin IPv4 address is checked")
        // Deleting the default route took down whole machines in v0.2.3; other tools' host routes are not ours.
        require(OpenConnectProcess.gatewayHostRoutes(addresses: gatewayIPs + ["10.66.17.254"], netstatOutput: table)
                == [StaleHostRoute(address: "77.242.243.181", hop: "10.66.34.254")!, StaleHostRoute(address: "188.116.30.172", hop: "10.66.33.254")!],
                "Only gateway host routes to the VPN server are candidates")
        require(OpenConnectProcess.isOffLink(hopRouteOutput: offLinkHop), "Router on a former subnet is stale")
        require(!OpenConnectProcess.isOffLink(hopRouteOutput: onLinkHop), "Router on the current subnet is kept")
        final class RouteRunner: ProcessRunning {
            let table: String
            var calls: [String] = []
            init(table: String) { self.table = table }
            func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult {
                calls.append(([executable] + arguments).joined(separator: " "))
                precondition(timeoutSeconds != nil, "Pre-connect probes must be bounded")
                switch arguments.last {
                case "vpn.example.com": return ProcessResult(exitCode: 0, stdout: "ip_address: 188.116.30.172\nip_address: 77.242.243.181\n", stderr: "")
                case "inet": return ProcessResult(exitCode: 0, stdout: table, stderr: "")
                case "10.66.33.254": return ProcessResult(exitCode: 0, stdout: "   route to: 10.66.33.254\ndestination: default\n    gateway: 10.66.17.254\n", stderr: "")
                case "10.66.34.254": return ProcessResult(exitCode: 0, stdout: "   route to: 10.66.34.254\ndestination: 10.66.34.0\n  interface: en0\n", stderr: "")
                default: return ProcessResult(exitCode: 1, stdout: "", stderr: "")
                }
            }
        }
        let routeRunner = RouteRunner(table: table)
        require(OpenConnectProcess.staleGatewayRoutes(host: "vpn.example.com", runner: routeRunner) == [StaleHostRoute(address: "188.116.30.172", hop: "10.66.33.254")!],
                "Only the off-link next hop is stale")
        require(routeRunner.calls.contains("/sbin/route -n get -host 10.66.33.254") && !routeRunner.calls.contains { $0.contains("delete") },
                "Detection looks up the next hop and never changes routes")
        let healthyRunner = RouteRunner(table: "default 10.66.17.254 UGScg en0\n188.116.30.172 10.66.17.254 UGHS en0\n")
        require(OpenConnectProcess.staleGatewayRoutes(host: "vpn.example.com", runner: healthyRunner).isEmpty, "Route via the current router is kept")
        require(StaleHostRoute(address: "1.2.3.4'; touch /tmp/x; '", hop: "10.0.0.1") == nil
                && StaleHostRoute(address: "default", hop: "10.0.0.1") == nil
                && StaleHostRoute(address: "10.66.17/24", hop: "10.0.0.1") == nil
                && StaleHostRoute(address: "1.2.3.4", hop: "link#14") == nil, "Only IPv4 literals reach root")
        let routeFixture = dir.appendingPathComponent("route-fixture")
        try FileManager.default.createDirectory(at: routeFixture, withIntermediateDirectories: true)
        let fakeRoute = routeFixture.appendingPathComponent("route").path
        try "#!/bin/sh\nif [ \"$2\" = get ]; then cat \"$(dirname \"$0\")/get\"; else echo \"$*\" >> \"$(dirname \"$0\")/deleted\"; fi\n"
            .write(toFile: fakeRoute, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeRoute)
        let removal = OpenConnectProcess.staleRouteRemovalCommand([StaleHostRoute(address: "188.116.30.172", hop: "10.66.33.254")!])
            .replacingOccurrences(of: "/sbin/route", with: PrivilegedCommand.quote(fakeRoute))
        let deleted = routeFixture.appendingPathComponent("deleted")
        for (current, expected) in [(staleGatewayRoute, "-n delete -host 188.116.30.172 10.66.33.254\n"), (defaultRoute, nil), (onLinkHop, nil)] {
            try? FileManager.default.removeItem(at: deleted)
            try current.write(to: routeFixture.appendingPathComponent("get"), atomically: true, encoding: .utf8)
            let ran = try SystemProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "set -eu\n" + removal], timeoutSeconds: 5)
            require(ran.succeeded, "Route removal must never abort the session launch")
            require((try? String(contentsOf: deleted, encoding: .utf8)) == expected, "Root deletes only the exact re-verified stale pair")
        }
        let withRoute = OpenConnectProcess.launchCommand(config: config, uid: getuid(), staleRoutes: [StaleHostRoute(address: "188.116.30.172", hop: "10.66.33.254")!])
        require(withRoute.contains("/sbin/route -n delete -host '188.116.30.172' '10.66.33.254'") && !withRoute.contains("delete default"), "Scoped deletion only")
        print("PASS: stale gateway host route detection and root-side exact-pair removal")

        try ManagedRuntime.checks(directory: FileManager.default.currentDirectoryPath + "/VPNMenuBar/Resources/BundledRuntime").write(to: dir.appendingPathComponent("validate.sh"), atomically: true, encoding: .utf8)
        try ManagedRuntime.stagingCommand.replacingOccurrences(of: ManagedRuntime.directory,
            with: FileManager.default.currentDirectoryPath + "/VPNMenuBar/Resources/BundledRuntime")
            .write(to: dir.appendingPathComponent("stage.sh"), atomically: true, encoding: .utf8)
        let dns = try ResolverFileManager.installationCommand(pending: [ResolverRule(domain: "intranet.example.com", nameserver: "10.0.0.53")], orphans: [])
        require(!dns.contains("NSTemporaryDirectory") && dns.contains("mktemp /etc/resolver/"), "Root-local staging only")
        require(dns.contains("grep -Fxq") && dns.contains("! -L"), "Check ownership/provenance and reject symlinks")
        mustFail { _ = try ResolverFileManager.installationCommand(pending: [], orphans: ["x\"; touch /tmp/injected"]) }
        mustFail { _ = try ResolverFileManager.installationCommand(pending: [ResolverRule(domain: "../../etc", nameserver: "10.0.0.1")], orphans: []) }
        require(!ResolverRule.rulesCapturingGateway([ResolverRule(domain: "example.com", nameserver: "10.0.0.1")], gatewayHost: "vpn.example.com").isEmpty, "Gateway protection")
        try dns.write(to: dir.appendingPathComponent("dns.sh"), atomically: true, encoding: .utf8)
        try DependencyInstaller.legacyRemovalCommand(username: "first.last").write(to: dir.appendingPathComponent("revoke.sh"), atomically: true, encoding: .utf8)
        print("PASS: DNS filename/gateway guards, root-local staging and provenance preflight")

        // Run the exact supervisor shell logic without authorization/root/network.
        let fixtureRuntime = dir.appendingPathComponent("fake-openconnect").path
        let fixtureScript = dir.appendingPathComponent("Application Support/vpnc-script").path
        try FileManager.default.createDirectory(atPath: (fixtureScript as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf 'SCRIPT_OK\\n'\n".write(toFile: fixtureScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureScript)
        let fake = """
        #!/bin/sh
        IFS= read -r credential
        [ "$credential" = fixture-password ] || exit 4
        [ "$1" = --script ] || exit 5
        /bin/sh -c "$2" || exit 6
        printf 'Connected as fixture\\n'
        # A real VPN runs a disconnect script before exiting; teardown must wait for it.
        trap '/bin/kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; /bin/sleep 0.3; printf "CLEANUP_DONE\\n"; exit 0' TERM
        while :; do /bin/sleep 120 & timer=$!; wait "$timer"; done
        """
        try fake.write(toFile: fixtureRuntime, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureRuntime)
        config.username = "fixture'; /usr/bin/touch " + PrivilegedCommand.quote(dir.appendingPathComponent("injected").path) + "; #"
        let fixture = OpenConnectProcess.launchCommand(config: config, uid: getuid())
            .replacingOccurrences(of: ManagedRuntime.validationCommand + "\n", with: "")
            .replacingOccurrences(of: DependencyInstaller.legacyRemovalCommand(username: NSUserName()) + "\n", with: "")
            .replacingOccurrences(of: "if [ ! -e /var/run/vpnc ]; then /bin/mkdir -m 755 /var/run/vpnc; fi\n", with: "")
            .replacingOccurrences(of: ManagedRuntime.stagingCommand, with:
                "/bin/mkdir -m 700 \"$session/runtime\"\n/bin/cp " + PrivilegedCommand.quote(fixtureRuntime)
                + " \"$session/runtime/openconnect\"\n/bin/cp " + PrivilegedCommand.quote(fixtureScript)
                + " \"$session/runtime/vpnc-script--no-dns\"")
            .replacingOccurrences(of: "/var/run/vpnmenubar.", with: dir.path + "/vpnmenubar.")
        // The session fixture never inspects or changes the real vpnc state directory.
        let safeFixture = fixture.components(separatedBy: "\n").filter {
            !$0.contains("/var/run/vpnc") && !$0.contains("0$mode & 022")
        }.joined(separator: "\n")
        try safeFixture.write(to: dir.appendingPathComponent("session.sh"), atomically: true, encoding: .utf8)
        print("PASS: nonprivileged supervisor fixture generated")

        let logs = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let old = logs.appendingPathComponent("vpnmenubar-2000-01-01.log")
        try Data("fixture".utf8).write(to: old)
        let logger = AppLogger(logDirectory: logs)
        logger.info("safe fixture event")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: logger.logFileURL.path) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: logger.logFileURL.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Log files private from creation")
        require(!FileManager.default.fileExists(atPath: old.path), "Expired logs removed")
        print("PASS: private log file creation and retention")
        let noisy = try SystemProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "/usr/bin/yes fixture | /usr/bin/head -c 200000; /usr/bin/yes fixture | /usr/bin/head -c 200000 >&2"], timeoutSeconds: 5)
        require(noisy.succeeded && noisy.stdout.utf8.count == 65_536 && noisy.stderr.utf8.count == 65_536, "Concurrent bounded pipe draining")
        print("PASS: large stdout/stderr cannot deadlock authorization runner")
    }
}
