import Foundation

/// Result of a one-shot command.
struct ProcessResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// Abstraction over `Process` for one-shot commands. Mockable in tests.
protocol ProcessRunning {
    /// Run the executable synchronously with the given args and return its result.
    /// Blocks the calling thread until the process exits or the timeout elapses —
    /// do not call from the main thread.
    /// - Parameters:
    ///   - executable: absolute path to the binary
    ///   - arguments: argv (not including argv[0])
    ///   - timeoutSeconds: if non-nil, the process is SIGTERM'd after the timeout
    ///                     and a result with exitCode = -1 is returned.
    func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult
}

/// Production implementation using Foundation.Process.
final class SystemProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], timeoutSeconds: TimeInterval?) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice

        try p.run()

        if let timeout = timeoutSeconds {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                p.terminate()
                // Give SIGTERM ~200ms to take effect, then escalate to SIGKILL.
                let killDeadline = Date().addingTimeInterval(0.2)
                while p.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
                p.waitUntilExit()
                return ProcessResult(exitCode: -1, stdout: "", stderr: "timeout")
            }
        } else {
            p.waitUntilExit()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: p.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
