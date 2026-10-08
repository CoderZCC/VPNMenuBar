import Foundation
import Darwin

enum OpenConnectHandshake: Equatable {
    case connected
    case failed(reason: String)
}

protocol OpenConnectProcessRunning: AnyObject {
    func prepare(config: VPNConfig) throws
    func start(config: VPNConfig, password: String) throws
    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake
    func isRunning() -> Bool
    func recentStderrTail(bytes: Int) -> String
    func stop() throws
}

extension OpenConnectProcessRunning {
    func prepare(config: VPNConfig) throws { }
}

/// A single authorized session. Credentials travel through private FIFOs, never
/// through AppleScript, argv or regular files. Closing control terminates our child.
final class OpenConnectProcess: OpenConnectProcessRunning {
    private var session: String?
    private var control: FileHandle?
    private var input: FileHandle?
    private var credentialsSent = false
    private var output: FileHandle?
    private var supervisorPID: pid_t?
    private var collectedOutput = Data()
    private let outputQueue = DispatchQueue(label: "vpnmenubar.session-output")

    func prepare(config: VPNConfig) throws {
        try stop()
        try ManagedRuntime.validateConfiguration(config)
        let path = try PrivilegedCommand.run(Self.launchCommand(config: config, uid: getuid()))
        guard Self.isSessionPath(path) else {
            throw DependencyInstallError.unsupported(reason: "Invalid response from the authorized VPN session.")
        }
        session = path
        guard let text = try? String(contentsOfFile: path + "/supervisor", encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw DependencyInstallError.unsupported(reason: "The authorized VPN session did not start.")
        }
        supervisorPID = pid
        do {
            // RDWR prevents FIFO-open deadlocks. Root owns the containing directory.
            output = try Self.openFIFO(path + "/output")
            input = try Self.openFIFO(path + "/input")
            credentialsSent = false
            control = try Self.openFIFO(path + "/control")
            outputQueue.sync { collectedOutput = Data() }
            output?.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                self?.outputQueue.sync {
                    self?.collectedOutput.append(chunk)
                    if let count = self?.collectedOutput.count, count > 65_536 {
                        self?.collectedOutput.removeFirst(count - 65_536)
                    }
                }
            }
        } catch {
            try? stop()
            throw error
        }
    }

    func start(config: VPNConfig, password: String) throws {
        guard let input, session != nil, !credentialsSent, password.utf8.count < 4096 else {
            throw DependencyInstallError.unsupported(reason: "The VPN session is not ready or credentials are too long.")
        }
        try input.write(contentsOf: Data((password + "\n").utf8))
        // Keep the FIFO open until stop: closing before the root reader opens it loses buffered bytes.
        credentialsSent = true
        AppLogger.shared.info("Authorized VPN session started")
    }

    func waitForHandshake(timeout: TimeInterval) async -> OpenConnectHandshake {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = snapshot()
            if let reason = Self.failureReason(text) { return .failed(reason: reason) }
            guard isRunning() else { return .failed(reason: "VPN process exited before the tunnel was established.") }
            if ["Connected as", "CSTP connected", "Established DTLS", "ESP session established"].contains(where: text.contains) {
                return .connected
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return .failed(reason: "VPN handshake timed out. Check the gateway settings or contact your VPN administrator.")
    }

    func isRunning() -> Bool {
        guard let session, let pid = supervisorPID,
              !FileManager.default.fileExists(atPath: session + "/status") else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func recentStderrTail(bytes: Int) -> String {
        // Only fixed classifications leave the in-memory output buffer.
        Self.failureReason(snapshot()) ?? "VPN process ended."
    }

    func stop() throws {
        // EOF is the sole control message; no executable, script or PID comes from the client.
        try? control?.close()
        control = nil
        try? input?.close()
        input = nil
        let deadline = Date().addingTimeInterval(15)
        while isRunning() && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard !isRunning() else {
            throw DependencyInstallError.unsupported(reason: "The VPN is still stopping. Retry before starting another connection.")
        }
        output?.readabilityHandler = nil
        try? output?.close()
        output = nil
        session = nil
        supervisorPID = nil
        outputQueue.sync { collectedOutput = Data() }
    }

    private func snapshot() -> String {
        outputQueue.sync { String(decoding: collectedOutput, as: UTF8.self) }
    }

    static func failureReason(_ text: String) -> String? {
        if text.contains("Certificate verification failure") {
            return "Server certificate verification failed. Check the configured certificate pin."
        }
        if ["Login failed", "authentication failure", "wrong otp value", "wrong otp pin"].contains(where: text.contains) {
            return "VPN authentication failed. Check credentials and device time with your administrator."
        }
        return nil
    }

    static func isSessionPath(_ path: String) -> Bool {
        let prefix = "/var/run/vpnmenubar."
        return path.hasPrefix(prefix) && path.count > prefix.count
            && path.dropFirst(prefix.count).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func openFIFO(_ path: String) throws -> FileHandle {
        let fd = open(path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600 else {
            close(fd)
            throw POSIXError(.EPERM)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func launchCommand(config: VPNConfig, uid: uid_t) -> String {
        let q = PrivilegedCommand.quote
        // OpenConnect evaluates --script with sh -c, after the outer shell parses argv.
        var arguments = ["--script", "./vpnc-script--no-dns",
                         "--user", config.username, "--passwd-on-stdin", "--servercert", config.serverCertPin]
        if let agent = config.effectiveUserAgent { arguments += ["--useragent", agent] }
        arguments += ["--", config.gateway]
        let invocation = arguments.map(q).joined(separator: " ")
        let supervisor = """
        session="$1"
        terminate_owned() {
          if [ -n "$1" ] && [ "$(/bin/ps -p "$1" -o ppid= | /usr/bin/tr -d ' ')" = "$$" ]; then
            /bin/kill -TERM "$1" 2>/dev/null || true
          fi
        }
        cleanup() {
          trap '' TERM INT HUP
          # Preserve the session until the VPN has exited and run its disconnect script.
          terminate_owned "${control_reader:-}"
          terminate_owned "${child:-}"
          terminate_owned "${startup_watch:-}"
          terminate_owned "${status_timer:-}"
          for worker in ${child:-} ${control_reader:-} ${startup_watch:-} ${status_timer:-}; do
            wait "$worker" 2>/dev/null || true
          done
          /bin/rm -rf "$session"
        }
        trap cleanup EXIT
        trap 'exit 0' TERM INT HUP
        # A client that disappears before attaching must not leave a privileged worker.
        ( timer=
          trap '/bin/kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true' EXIT
          trap 'exit 0' TERM INT HUP
          remaining=60
          while [ ! -e "$session/attached" ] && [ "$remaining" -gt 0 ]; do
            /bin/sleep 1 & timer=$!
            wait "$timer"
            timer=
            remaining=$((remaining - 1))
          done
          if [ ! -e "$session/attached" ]; then /bin/kill -TERM "$$"; fi
        ) &
        startup_watch=$!
        exec 3<"$session/control"
        /usr/bin/touch "$session/attached"
        # Let the watchdog observe attachment; signal cancellation can race its traps.
        wait "$startup_watch" 2>/dev/null || true
        startup_watch=
        cd "$session/runtime" || exit 1
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root GNUTLS_SYSTEM_PRIORITY_FILE=/dev/null P11_KIT_NO_USER_CONFIG=1 ./openconnect \(invocation) <"$session/input" >"$session/output" 2>&1 3<&- &
        child=$!
        ( IFS= read -r ignored <&3 || true
          if [ "$(/bin/ps -p "$child" -o ppid= | /usr/bin/tr -d ' ')" = "$$" ]; then /bin/kill -TERM "$child" 2>/dev/null || true; fi
        ) &
        control_reader=$!
        wait "$child"
        status=$?
        child=
        /bin/kill "$control_reader" 2>/dev/null || true
        wait "$control_reader" 2>/dev/null || true
        control_reader=
        /bin/echo "$status" > "$session/status"
        # Keep a brief status window for the client, then remove only this root-created directory.
        /bin/sleep 30 &
        status_timer=$!
        wait "$status_timer"
        status_timer=
        """
        return "set -eu\nexport PATH=/usr/bin:/bin:/usr/sbin:/sbin\nunset DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_FRAMEWORK_PATH DYLD_FALLBACK_LIBRARY_PATH\n" + DependencyInstaller.legacyRemovalCommand(username: NSUserName()) + "\n" + """
        umask 077
        if [ ! -e /var/run/vpnc ]; then /bin/mkdir -m 755 /var/run/vpnc; fi
        [ -d /var/run/vpnc ] && [ ! -L /var/run/vpnc ] || exit 40
        [ "$(/usr/bin/stat -f %u /var/run/vpnc)" = 0 ] || exit 41
        mode=$(/usr/bin/stat -f %Lp /var/run/vpnc)
        [ $((0$mode & 022)) -eq 0 ] || exit 42
        case "$(/bin/ls -lde /var/run/vpnc | /usr/bin/awk '{print $1}')" in *+*) exit 43;; esac
        session=$(/usr/bin/mktemp -d /var/run/vpnmenubar.XXXXXXXX)
        trap '/bin/rm -rf "$session"' EXIT
        \(ManagedRuntime.stagingCommand)
        /usr/bin/mkfifo "$session/input" "$session/output" "$session/control"
        /usr/sbin/chown \(uid) "$session/input" "$session/output" "$session/control"
        /bin/chmod 600 "$session/input" "$session/output" "$session/control"
        /bin/chmod 711 "$session"
        # Authorization ignores and blocks SIGTERM; restore dispositions and the inherited mask.
        /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/perl -MPOSIX -e 'for (qw(HUP INT TERM PIPE)) { $SIG{$_} = "DEFAULT" } defined(POSIX::sigprocmask(POSIX::SIG_SETMASK(), POSIX::SigSet->new())) or exit 126; exec @ARGV; exit 127' /bin/sh -c \(q(supervisor)) VPNMenuBar-session "$session" </dev/null >/dev/null 2>&1 &
        /bin/echo "$!" > "$session/supervisor"
        /bin/chmod 644 "$session/supervisor"
        trap - EXIT
        /bin/echo "$session"
        """
    }

    static func extractHost(from gateway: String) -> String {
        let value = gateway.contains("://") ? gateway : "https://" + gateway
        return URLComponents(string: value)?.host ?? ""
    }
}
