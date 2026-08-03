import Foundation
import AppKit

enum DependencyInstallError: Error, LocalizedError {
    case userCancelled
    case shellFailed(stderr: String)
    case osascriptFailed(message: String)
    case unsupported(reason: String)
    case configIO(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Cancelled."
        case .shellFailed(let s):
            return s.isEmpty ? "Shell command failed." : s
        case .osascriptFailed(let m):
            return m
        case .unsupported(let r):
            return r
        case .configIO(let e):
            return "Config I/O failed: \(e.localizedDescription)"
        }
    }
}

/// Stateless namespace exposing the four fix actions surfaced by
/// `InAppFix`. UI views invoke these from a dispatcher tied to a
/// `runningFix` state and an error alert.
enum DependencyInstaller {

    /// Open Terminal.app and pre-type the official Homebrew installer
    /// command. Returns immediately. The user runs the command in
    /// Terminal and comes back to click Recheck.
    static func openTerminalForHomebrew() throws {
        AppLogger.shared.info("DependencyInstaller: opening Terminal with Homebrew installer command")
        let installerCmd = "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        let escaped = appleScriptEscape(installerCmd)
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        do {
            try runAppleScript(source)
        } catch {
            AppLogger.shared.error("DependencyInstaller.openTerminalForHomebrew failed: \(error)")
            throw error
        }
    }

    /// Run `brew install openconnect` as the current user via Process.
    /// Streams stdout+stderr lines to the progress callback.
    /// Throws `shellFailed(stderr:)` on non-zero exit.
    static func installOpenconnect(
        brewPath: String,
        progress: @Sendable @escaping (String) -> Void
    ) async throws {
        AppLogger.shared.info("DependencyInstaller: brew install openconnect starting (brewPath=\(brewPath))")
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: brewPath)
            p.arguments = ["install", "openconnect"]

            // brew needs its own bin dir on PATH so it can find auxiliary tools.
            let brewDir = (brewPath as NSString).deletingLastPathComponent
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(brewDir):/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            p.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.standardInput = FileHandle.nullDevice

            // Accumulate stderr for the failure tail; also forward live lines to UI.
            let stderrAccum = StderrAccumulator()

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                if let s = String(data: chunk, encoding: .utf8) {
                    for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        progress(String(line))
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                stderrAccum.append(chunk)
                if let s = String(data: chunk, encoding: .utf8) {
                    for line in s.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        progress(String(line))
                    }
                }
            }

            try p.run()
            p.waitUntilExit()
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            if p.terminationStatus != 0 {
                let stderrText = stderrAccum.snapshotString()
                let tail = String(stderrText.suffix(400))
                AppLogger.shared.error("DependencyInstaller: brew install openconnect exited \(p.terminationStatus)\nstderr tail:\n\(tail)")
                throw DependencyInstallError.shellFailed(
                    stderr: tail.isEmpty ? "brew install exited \(p.terminationStatus)" : tail
                )
            }
        }.value
        AppLogger.shared.info("DependencyInstaller: brew install openconnect succeeded")
    }

    /// Write /etc/sudoers.d/vpnmenubar-<sanitized-user> via osascript admin (one TouchID).
    /// Validates with visudo before installing.
    static func installSudoersRule(
        username: String,
        openconnectPath: String
    ) async throws {
        AppLogger.shared.info("DependencyInstaller: installing sudoers rule for \(username) (openconnectPath=\(openconnectPath))")
        do {
            try await Task.detached(priority: .userInitiated) {
                // sudo SILENTLY IGNORES files in /etc/sudoers.d whose names contain a
                // '.' (or end in '~'). An AD-style username like "first.last" would
                // otherwise produce a rule that never takes effect. Sanitize any char
                // outside [A-Za-z0-9_-] to '_' for the FILENAME only — the username
                // inside the rule keeps its original form (dots are fine there).
                let safeName = String(username.map {
                    ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" ? $0 : "_"
                })
                let dest = "/etc/sudoers.d/vpnmenubar-\(safeName)"
                let legacyDest = "/etc/sudoers.d/vpnmenubar-\(username)"

                // 1. Build content
                let content = """
                # Auto-generated by VPNMenuBar at \(Date())
                # Grants \(username) passwordless sudo for openconnect, pkill, and route.
                # Remove this file to revoke: sudo rm \(dest)
                \(username) ALL=(root) NOPASSWD: \(openconnectPath), /usr/bin/pkill -x openconnect, /sbin/route
                """

                // 2. Write to a user-owned temp file
                let tmp = NSTemporaryDirectory() + "vpnmenubar-sudoers-\(UUID().uuidString)"
                try content.write(toFile: tmp, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: tmp) }

                // 3. Build privileged shell command. If the username needed
                // sanitizing, also remove any pre-existing (silently-ignored)
                // dotted legacy file so it doesn't linger on disk.
                var shellCmd = "/usr/sbin/visudo -c -f \"\(tmp)\" && /usr/bin/install -m 440 -o root -g wheel \"\(tmp)\" \"\(dest)\""
                if legacyDest != dest {
                    shellCmd += " && /bin/rm -f \"\(legacyDest)\""
                }

                // 4. Wrap in AppleScript with admin privileges (one TouchID)
                let asEscaped = appleScriptEscape(shellCmd)
                let source = """
                do shell script "\(asEscaped)" with administrator privileges
                """
                try runAppleScript(source)
            }.value
            AppLogger.shared.info("DependencyInstaller: sudoers rule installed for \(username)")
        } catch {
            AppLogger.shared.error("DependencyInstaller.installSudoersRule failed: \(error)")
            throw error
        }
    }

    /// Reset the vpncScriptPath in saved config to the architecture-correct
    /// default. No privilege escalation needed — just a config write.
    static func resetVpncScriptPath(to newPath: String, store: ConfigStore) throws {
        AppLogger.shared.info("DependencyInstaller: reset vpncScriptPath to \(newPath)")
        do {
            guard var config = try store.load() else {
                throw DependencyInstallError.unsupported(
                    reason: "No config to update yet — finish Onboarding first."
                )
            }
            config.vpncScriptPath = newPath
            try store.save(config)
        } catch let e as DependencyInstallError {
            AppLogger.shared.error("DependencyInstaller.resetVpncScriptPath failed: \(e)")
            throw e
        } catch {
            AppLogger.shared.error("DependencyInstaller.resetVpncScriptPath config I/O failed: \(error)")
            throw DependencyInstallError.configIO(underlying: error)
        }
    }

    // MARK: - helpers

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Execute an AppleScript source string. Maps the well-known cancel
    /// code (-128) to `userCancelled`; everything else to `osascriptFailed`.
    private static func runAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw DependencyInstallError.osascriptFailed(message: "Could not build AppleScript")
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 {
                throw DependencyInstallError.userCancelled
            }
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
            throw DependencyInstallError.osascriptFailed(message: "\(msg) (code \(code))")
        }
    }
}

/// Tiny mutex-protected wrapper so the Pipe readabilityHandler thread can
/// append to the stderr accumulator without racing the consumer thread.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshotString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
