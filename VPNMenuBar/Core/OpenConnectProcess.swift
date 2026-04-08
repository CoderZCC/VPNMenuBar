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
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        process = nil
        collectedStderr = Data()

        // Scrub a leftover host route to the VPN gateway whose nexthop points
        // at a previous-WiFi gateway. Best-effort: silently no-ops if the
        // sudoers entry is missing or no stale route is present.
        cleanupStaleHostRoute(forGateway: config.gateway)

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

            // Success keyword + our child still alive → connected.
            let keywordHit = successMarkers.contains { stderrText.contains($0) }
            let gracePassed = Date().timeIntervalSince(startTime) >= gracePeriod
            if p.isRunning && (keywordHit || gracePassed) && pgrepOpenConnect() {
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

    // MARK: - stale host-route cleanup

    /// Inspect the kernel routing table for a host route to the VPN gateway
    /// whose nexthop is no longer reachable (typical after switching WiFi
    /// while openconnect was killed without running vpnc-script's disconnect
    /// phase) and delete it. Best-effort and silent: any failure here just
    /// lets openconnect proceed and surface its native error.
    private func cleanupStaleHostRoute(forGateway gateway: String) {
        let host = Self.extractHost(from: gateway)
        guard !host.isEmpty else { return }

        // Current default route's nexthop — what a freshly-added host route
        // *should* point at on this network.
        let defaultRoute = (try? processRunner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", "default"],
            timeoutSeconds: 2
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")
        guard defaultRoute.succeeded,
              let defaultGateway = Self.parseRouteField("gateway", from: defaultRoute.stdout) else {
            return
        }

        // Existing route to the VPN host (does its own DNS resolution).
        let hostRoute = (try? processRunner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", host],
            timeoutSeconds: 2
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")
        guard hostRoute.succeeded,
              let routeGateway = Self.parseRouteField("gateway", from: hostRoute.stdout),
              let destinationIP = Self.parseRouteField("destination", from: hostRoute.stdout) else {
            return
        }

        // If the route falls through to the current default gateway, it's
        // already correct — touching it would break a healthy connection.
        guard routeGateway != defaultGateway else { return }

        NSLog("VPNMenuBar: stale host route to %@ via %@ detected (default gw %@) — deleting",
              destinationIP, routeGateway, defaultGateway)

        let result = (try? processRunner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/sbin/route", "-n", "delete", destinationIP],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")
        if !result.succeeded {
            NSLog("VPNMenuBar: route delete failed (sudoers may be missing /sbin/route — re-run install-deps.sh): %@",
                  result.stderr)
        }
    }

    /// Strip optional `https://` scheme and any `:port` / `/path` suffix
    /// from a gateway string, leaving just the host.
    private static func extractHost(from gateway: String) -> String {
        var s = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { $0 == "/" || $0 == ":" }) {
            s = String(s[..<i])
        }
        return s
    }

    /// Parse a `field: value` line out of `route -n get` output (the field
    /// is preceded by variable indentation).
    private static func parseRouteField(_ field: String, from output: String) -> String? {
        let prefix = "\(field):"
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
