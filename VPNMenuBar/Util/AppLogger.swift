import Foundation

enum AppLogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// File-based logger for user-facing diagnostics. Writes to
/// `~/Library/Logs/VPNMenuBar/vpnmenubar.log` and also mirrors each line to
/// `NSLog` so it remains visible in Console.app. Callers are responsible for
/// redacting secrets before logging — this class does not inspect payloads.
final class AppLogger {
    static let shared = AppLogger()

    let logDirectory: URL
    let logFileURL: URL

    private let queue = DispatchQueue(label: "com.example.vpnmenubar.applogger", qos: .utility)
    private let formatter: DateFormatter
    private let maxBytes: Int = 1_000_000

    private init() {
        let libraryLogs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/VPNMenuBar", isDirectory: true)
        self.logDirectory = libraryLogs
        self.logFileURL = libraryLogs.appendingPathComponent("vpnmenubar.log")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = f

        try? FileManager.default.createDirectory(at: libraryLogs, withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    func info(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.info, message, file: file, line: line)
    }

    func warn(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.warn, message, file: file, line: line)
    }

    func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }

    private func log(_ level: AppLogLevel, _ message: String, file: String, line: Int) {
        let ts = formatter.string(from: Date())
        let short = file.split(separator: "/").last.map(String.init) ?? file
        let entry = "\(ts) [\(level.rawValue)] \(short):\(line) \(message)\n"
        NSLog("VPNMenuBar: [%{public}@] %{public}@", level.rawValue, message)
        queue.async { [weak self] in
            self?.appendToFile(entry)
        }
    }

    private func appendToFile(_ entry: String) {
        guard let data = entry.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            try? data.write(to: logFileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        do { try handle.write(contentsOf: data) } catch { /* best-effort */ }
    }

    /// Rotate the log when it exceeds `maxBytes`. Keeps a single `.1` archive
    /// (overwritten each rotation) — this is a personal-use menu-bar app, no
    /// need for N-generation retention.
    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else {
            return
        }
        let backup = logFileURL.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: logFileURL, to: backup)
    }
}
