import Foundation

final class ConfigStore {
    private let baseDirectory: URL
    let configURL: URL

    /// Production initializer — writes to ~/Library/Application Support/com.example.vpnmenubar/
    convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        self.init(baseDirectory: appSupport.appendingPathComponent("com.example.vpnmenubar", isDirectory: true))
    }

    /// Test initializer — inject any base directory.
    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.configURL = baseDirectory.appendingPathComponent("config.json")
    }

    var isConfigured: Bool {
        (try? load())?.isConfigured ?? false
    }

    func load() throws -> VPNConfig? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configURL.path) else { return nil }
        let data = try Data(contentsOf: configURL)
        do {
            // Sanitize on the way out so legacy configs written before the
            // whitespace-stripping was added still surface clean values to
            // connect() without waiting for a user-initiated save.
            return try JSONDecoder().decode(VPNConfig.self, from: data).sanitized()
        } catch {
            AppLogger.shared.error("config decode failed (\(error)) — backing up broken file")
            try backupBrokenFile()
            return nil
        }
    }

    func save(_ config: VPNConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config.sanitized())

        // Atomic write: temp file + rename.
        let tmpURL = configURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: configURL.path) {
            _ = try fm.replaceItemAt(configURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: configURL)
        }

        // Enforce 0600.
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: configURL.path
        )
    }

    private func backupBrokenFile() throws {
        let fm = FileManager.default
        let epoch = Int(Date().timeIntervalSince1970)
        let backupURL = configURL.appendingPathExtension("broken-\(epoch)")
        try fm.moveItem(at: configURL, to: backupURL)
    }
}
