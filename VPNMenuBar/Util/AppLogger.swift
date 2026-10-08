import Foundation

enum AppLogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

/// File-based logger for user-facing diagnostics. Writes per-day log files
/// `~/Library/Logs/VPNMenuBar/vpnmenubar-YYYY-MM-DD.log` without mirroring message contents to system logs. Old files are purged daily. Callers are responsible for redacting secrets — this class does not
/// inspect payloads.
final class AppLogger {
    static let shared = AppLogger()

    let logDirectory: URL

    private let queue = DispatchQueue(label: "com.example.vpnmenubar.applogger", qos: .utility)
    private let timestampFormatter: DateFormatter
    private let dateFormatter: DateFormatter
    private let retentionDays: Int = 3
    private var lastPurgeDay = ""
    private let filePrefix = "vpnmenubar-"
    private let fileSuffix = ".log"

    init(logDirectory: URL? = nil) {
        let defaultLogs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/VPNMenuBar", isDirectory: true)
        let libraryLogs = logDirectory ?? defaultLogs
        self.logDirectory = libraryLogs

        let ts = DateFormatter()
        ts.locale = Locale(identifier: "en_US_POSIX")
        ts.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.timestampFormatter = ts

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = day

        try? FileManager.default.createDirectory(at: libraryLogs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: libraryLogs.path)
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
        queue.async { [weak self] in
            self?.appendToFile(entry, at: now)
        }
    }

    private func appendToFile(_ entry: String, at date: Date) {
        guard let data = entry.data(using: .utf8) else { return }
        let url = logDirectory.appendingPathComponent("\(filePrefix)\(dateFormatter.string(from: date))\(fileSuffix)")
        let fm = FileManager.default
        let day = dateFormatter.string(from: date)
        if lastPurgeDay != day {
            purgeOldLogs()
            lastPurgeDay = day
        }
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size + data.count <= 2 * 1024 * 1024 else { return }
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
