import Foundation

enum AppLogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// File-based logger for user-facing diagnostics. Writes per-day log files
/// `~/Library/Logs/VPNMenuBar/vpnmenubar-YYYY-MM-DD.log` and mirrors each line
/// to `NSLog` for Console.app. Files older than `retentionDays` are purged at
/// launch. Callers are responsible for redacting secrets — this class does not
/// inspect payloads.
final class AppLogger {
    static let shared = AppLogger()

    let logDirectory: URL

    private let queue = DispatchQueue(label: "com.example.vpnmenubar.applogger", qos: .utility)
    private let timestampFormatter: DateFormatter
    private let dateFormatter: DateFormatter
    private let retentionDays: Int = 14
    private let filePrefix = "vpnmenubar-"
    private let fileSuffix = ".log"

    private init() {
        let libraryLogs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/VPNMenuBar", isDirectory: true)
        self.logDirectory = libraryLogs

        let ts = DateFormatter()
        ts.locale = Locale(identifier: "en_US_POSIX")
        ts.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.timestampFormatter = ts

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = day

        try? FileManager.default.createDirectory(at: libraryLogs, withIntermediateDirectories: true)
        purgeOldLogs()
    }

    /// URL of today's log file. Re-computed each call so consumers (menu /
    /// Settings "Reveal in Finder") always land on the current-day file.
    var logFileURL: URL {
        logDirectory.appendingPathComponent("\(filePrefix)\(dateFormatter.string(from: Date()))\(fileSuffix)")
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
        let now = Date()
        let ts = timestampFormatter.string(from: now)
        let short = file.split(separator: "/").last.map(String.init) ?? file
        let entry = "\(ts) [\(level.rawValue)] \(short):\(line) \(message)\n"
        NSLog("VPNMenuBar: [%{public}@] %{public}@", level.rawValue, message)
        queue.async { [weak self] in
            self?.appendToFile(entry, at: now)
        }
    }

    private func appendToFile(_ entry: String, at date: Date) {
        guard let data = entry.data(using: .utf8) else { return }
        let url = logDirectory.appendingPathComponent("\(filePrefix)\(dateFormatter.string(from: date))\(fileSuffix)")
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        do { try handle.write(contentsOf: data) } catch { /* best-effort */ }
    }

    /// Delete per-day log files older than `retentionDays`. Called once at
    /// launch — running apps are expected to restart occasionally, and the
    /// disk cost of one extra old file in a day is negligible.
    private func purgeOldLogs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            ?? Date(timeIntervalSinceNow: -Double(retentionDays) * 86_400)
        let cutoffDay = dateFormatter.string(from: cutoff)
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { continue }
            let datePart = String(name.dropFirst(filePrefix.count).dropLast(fileSuffix.count))
            // Lexicographic compare works because dateFormat is yyyy-MM-dd.
            if datePart < cutoffDay {
                try? fm.removeItem(at: url)
            }
        }
    }
}
