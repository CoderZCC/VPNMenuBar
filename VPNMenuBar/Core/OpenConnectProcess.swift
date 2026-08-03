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
    /// `password` may itself contain a newline — openconnect consumes one
    /// stdin line per password-type form field, so a two-step gateway gets
    /// "password\notp\n". Returns after the process is spawned (not after
    /// handshake).
    func start(config: VPNConfig, password: String) throws

    /// Wait for initial handshake success or failure.
    /// Returns within `timeout` seconds; does NOT block after success.
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake

    /// Is the spawned openconnect still running?
    func isRunning() -> Bool

    /// Tail of the captured stderr (best effort). Used by the watchdog to
    /// surface the openconnect death reason in the app log when the child
    /// vanishes after a successful handshake.
    func recentStderrTail(bytes: Int) -> String

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
        // Clean up any prior invocation — and WAIT for it to actually die.
        // A SIGTERM'd openconnect runs vpnc-script's disconnect phase
        // asynchronously (deleting routes by destination, regardless of
        // interface). If we spawn the new session before that cleanup
        // finishes, it deletes the routes the new session just installed,
        // leaving a live tunnel with an empty routing table.
        try? stop()
        let stopDeadline = Date().addingTimeInterval(5)
        while pgrepOpenConnect() && Date() < stopDeadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
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
            // Without -v the stderr only carries openconnect's last-resort
            // message ("Basic authentication is disabled"), which hides the
            // actual HTTP status that caused it. Cookies are scrubbed before
            // anything reaches the log file — see redactSecrets.
            "-v",
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
        AppLogger.shared.info("openconnect spawned, argv: \((p.arguments ?? []).joined(separator: " "))")
        // A two-step gateway asks for a second auth form; if we fed it only one
        // stdin line openconnect hits EOF and falls back to HTTP Basic, whose
        // "basic auth disabled" error looks nothing like the real cause.
        AppLogger.shared.info("writing \(password.split(separator: "\n", omittingEmptySubsequences: false).count) stdin line(s) to openconnect")
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
            "wrong otp value",
            "wrong otp pin",
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
                dumpStderrForDiagnosis(stderrText, context: "matched marker \"\(marker)\"")
                return .failed(reason: reason)
            }

            // Process already exited during handshake phase → failure.
            if !p.isRunning {
                let reason = tailOfStderr(stderrText, bytes: 200)
                dumpStderrForDiagnosis(stderrText, context: "openconnect exited during handshake")
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
        dumpStderrForDiagnosis(stderrText, context: "handshake timeout")
        return .failed(reason: reason.isEmpty ? "Handshake timeout" : reason)
    }

    func isRunning() -> Bool {
        pgrepOpenConnect()
    }

    func recentStderrTail(bytes: Int) -> String {
        let stderrText = stderrQueue.sync {
            String(data: collectedStderr, encoding: .utf8) ?? ""
        }
        return tailOfStderr(stderrText, bytes: bytes)
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

    /// Dump the full captured openconnect stderr to the system log so the
    /// user can inspect the raw output (e.g. the actual server pin-sha256,
    /// cert subject/issuer) via Console.app — the UI reason string is kept
    /// short on purpose.
    private func dumpStderrForDiagnosis(_ stderrText: String, context: String) {
        let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            AppLogger.shared.error("openconnect failed (\(context)), stderr was empty")
            return
        }
        AppLogger.shared.error("openconnect failed (\(context)). Full stderr:\n\(redactSecrets(trimmed))")
    }

    /// -v makes openconnect echo session cookies; those are bearer credentials
    /// and must never reach the log file the user mails around for support.
    private func redactSecrets(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let lower = line.lowercased()
                guard lower.hasPrefix("set-cookie:") || lower.hasPrefix("cookie:") else {
                    return String(line)
                }
                guard let colon = line.firstIndex(of: ":"),
                      let equals = line[line.index(after: colon)...].firstIndex(of: "=") else {
                    return String(line[...(line.firstIndex(of: ":") ?? line.startIndex)]) + " <redacted>"
                }
                return String(line[...equals]) + "<redacted>"
            }
            .joined(separator: "\n")
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
        case "wrong otp value", "wrong otp pin":
            return "OTP rejected by server. Verify your authenticator code matches the server's expectation. If your secret and time are correct, the token may have been disabled — contact IT to reset it."
        default:
            return tailOfStderr(fullStderr, bytes: 200)
        }
    }

    // MARK: - pre-connect host-route cleanup

    /// Delete the cached host route to the VPN gateway before spawning
    /// openconnect — ONLY when a dedicated host route actually exists. If no
    /// such route is present `/sbin/route get` falls through to the default
    /// route and reports `destination: default`; in that case we MUST NOT
    /// run a delete (that would wipe the system default route and kill all
    /// networking). A dedicated host route always has a concrete IPv4 as its
    /// destination, so we gate the delete on that.
    ///
    /// Called at the top of `start()` — no active tunnel exists at that
    /// point, so deleting a concrete host route is safe: a correct one is
    /// rebuilt by the kernel on the next packet; a stale one is what we want
    /// gone. Best-effort — failures are logged and openconnect proceeds.
    private func cleanupStaleHostRoute(forGateway gateway: String) {
        let host = Self.extractHost(from: gateway)
        guard !host.isEmpty else { return }

        // Route lookup (does its own DNS resolution).
        let hostRoute = (try? processRunner.run(
            executable: "/sbin/route",
            arguments: ["-n", "get", host],
            timeoutSeconds: 2
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")
        guard hostRoute.succeeded,
              let destinationIP = Self.parseRouteField("destination", from: hostRoute.stdout) else {
            return
        }

        // Critical safety guard: only delete when destination is a concrete
        // IPv4 address. If it's "default" (or any other non-IP literal) we
        // hit fall-through to the default route and deleting would kill the
        // box's entire network.
        guard Self.isConcreteIPv4(destinationIP) else {
            AppLogger.shared.info("pre-connect: no dedicated host route for \(host) (got destination=\(destinationIP)) — skipping flush")
            return
        }

        let currentGateway = Self.parseRouteField("gateway", from: hostRoute.stdout) ?? "?"
        AppLogger.shared.info("pre-connect: flushing cached route to \(destinationIP) (was via \(currentGateway))")

        let result = (try? processRunner.run(
            executable: "/usr/bin/sudo",
            arguments: ["-n", "/sbin/route", "-n", "delete", destinationIP],
            timeoutSeconds: 3
        )) ?? ProcessResult(exitCode: -1, stdout: "", stderr: "")
        if !result.succeeded {
            AppLogger.shared.error("pre-connect route flush failed (sudoers may be missing /sbin/route — re-run install-deps.sh): \(result.stderr)")
        }
    }

    /// Strict dotted-quad IPv4 check (0-255 per octet). Used as a safety gate
    /// so `route get` fall-through sentinels like "default" never reach the
    /// delete path.
    private static func isConcreteIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let n = Int(part), n >= 0, n <= 255 else { return false }
            return true
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
