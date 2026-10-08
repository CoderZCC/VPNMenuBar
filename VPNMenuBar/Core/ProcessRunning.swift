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
        // Drain both pipes while the process runs; authorization errors can include a large command.
        let stdout = ProcessOutputBuffer()
        let stderr = ProcessOutputBuffer()
        let readers = DispatchGroup()
        for (handle, buffer) in [(outPipe.fileHandleForReading, stdout), (errPipe.fileHandleForReading, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty { buffer.append(chunk) }
            }
        }
        var timedOut = false
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
                timedOut = true
            }
        } else {
            p.waitUntilExit()
        }

        p.waitUntilExit()
        readers.wait()
        return ProcessResult(exitCode: timedOut ? -1 : p.terminationStatus,
                             stdout: stdout.text,
                             stderr: timedOut ? "timeout" : stderr.text)
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 65_536 { data.removeFirst(data.count - 65_536) }
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
