import Foundation
import Security

enum ConfigStoreError: LocalizedError {
    case invalidConfiguration
    case cleanupFailed
    case configurationStillReadable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The configuration could not be read. The original file has been preserved."
        case .configurationStillReadable:
            return "The configuration is readable. Use Settings to edit it instead of resetting it."
        case .cleanupFailed:
            return "Credentials were encrypted and saved, but an old credential copy could not be removed. Check configuration folder permissions and retry."
        }
    }
}

final class ConfigStore {
    private let baseDirectory: URL
    private let credentials: CredentialStoring
    let configURL: URL

    convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        // Keep the legacy directory so the new bundle identity can migrate existing settings.
        let directory = appSupport.appendingPathComponent("com.example.vpnmenubar", isDirectory: true)
        self.init(baseDirectory: directory, credentials: LocalCredentialStore(baseDirectory: directory))
    }

    init(baseDirectory: URL, credentials: CredentialStoring) {
        self.baseDirectory = baseDirectory
        self.configURL = baseDirectory.appendingPathComponent("config.json")
        self.credentials = credentials
    }

    var hasConfiguration: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    /// Called only after explicit confirmation. Move the original, never copy secrets.
    func recoverUnreadableConfiguration() throws {
        guard hasConfiguration else { return }
        do {
            _ = try loadSettings()
            throw ConfigStoreError.configurationStillReadable
        } catch ConfigStoreError.invalidConfiguration {
            let stamp = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let backup = configURL.appendingPathExtension("broken-\(stamp)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            try FileManager.default.moveItem(at: configURL, to: backup)
        }
    }

    func load() throws -> VPNConfig? {
        guard hasConfiguration else { return nil }
        let data = try Data(contentsOf: configURL)
        let header = try decode(Header.self, from: data)
        if header.schemaVersion == 2 { throw CredentialStoreError.legacyKeychainConfiguration }
        if header.schemaVersion == 3 {
            let stored = try decode(StoredConfig.self, from: data)
            let secret = try credentials.read(reference: stored.credentialReference)
            try cleanup(stored)
            return stored.config(credentials: secret).sanitized()
        }
        guard header.schemaVersion == 1 else { throw ConfigStoreError.invalidConfiguration }
        let legacy = try decode(VPNConfig.self, from: data).sanitized()
        // Never remove plaintext until the encrypted store has returned both secrets.
        try save(legacy)
        return legacy
    }

    /// Dependency checks need paths and DNS rules, never decrypted credentials.
    func loadSettings() throws -> VPNConfig? {
        guard hasConfiguration else { return nil }
        let data = try Data(contentsOf: configURL)
        let header = try decode(Header.self, from: data)
        if header.schemaVersion == 2 || header.schemaVersion == 3 {
            return try decode(StoredConfig.self, from: data)
                .config(credentials: VPNCredentials(passwordPrefix: "", totpSecret: ""))
        }
        guard header.schemaVersion == 1 else { throw ConfigStoreError.invalidConfiguration }
        var config = try decode(VPNConfig.self, from: data).sanitized()
        config.passwordPrefix = ""
        config.totpSecret = ""
        return config
    }

    func save(_ config: VPNConfig, replacingMissingCredentials: Bool = false) throws {
        let fm = FileManager.default
        var retiredReferences: [String] = []
        if hasConfiguration {
            let oldData = try Data(contentsOf: configURL)
            let header = try decode(Header.self, from: oldData)
            if header.schemaVersion == 2 {
                _ = try decode(StoredConfig.self, from: oldData)
                guard replacingMissingCredentials else { throw CredentialStoreError.legacyKeychainConfiguration }
                // Never treat a legacy Keychain reference as a local file to delete.
            } else if header.schemaVersion == 3 {
                let previous = try decode(StoredConfig.self, from: oldData)
                // An inaccessible credential store must not be mistaken for an empty account.
                do {
                    _ = try credentials.read(reference: previous.credentialReference)
                } catch let error as CredentialStoreError where replacingMissingCredentials && error.canReenterCredentials {
                    // Only an explicit recovery action may replace a missing item, never a locked one.
                }
                retiredReferences = (previous.retiredCredentialReferences ?? []) + [previous.credentialReference]
            } else {
                guard header.schemaVersion == 1 else { throw ConfigStoreError.invalidConfiguration }
                _ = try decode(VPNConfig.self, from: oldData)
            }
        }
        let clean = config.sanitized()
        let secret = VPNCredentials(passwordPrefix: clean.passwordPrefix, totpSecret: clean.totpSecret)
        let reference = UUID().uuidString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var stored = StoredConfig(config: clean, reference: reference)
        stored.retiredCredentialReferences = retiredReferences.isEmpty ? nil : retiredReferences
        let data = try encoder.encode(stored)
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try credentials.add(secret, reference: reference)
        do {
            guard try credentials.read(reference: reference) == secret else {
                throw CredentialStoreError.invalidData
            }
            // A fresh item keeps the old JSON/credential pair intact if writing JSON fails.
            try writeSettings(data)
        } catch {
            try? credentials.delete(reference: reference)
            throw error
        }
        try cleanup(stored)
    }

    private func cleanup(_ stored: StoredConfig) throws {
        do {
            for reference in stored.retiredCredentialReferences ?? [] where reference != stored.credentialReference {
                try credentials.delete(reference: reference)
            }
            try cleanupLegacyFiles()
            if stored.retiredCredentialReferences != nil {
                var cleaned = stored
                cleaned.retiredCredentialReferences = nil
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try writeSettings(encoder.encode(cleaned))
            }
        } catch {
            throw ConfigStoreError.cleanupFailed
        }
    }

    private func writeSettings(_ data: Data) throws {
        let fm = FileManager.default
        let tmp = baseDirectory.appendingPathComponent(".settings-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { try? fm.removeItem(at: tmp) }
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        // rename preserves the new file's 0600 mode when replacing a legacy file.
        guard rename(tmp.path, configURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func cleanupLegacyFiles() throws {
        let fm = FileManager.default
        do {
            for url in try fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                let suffix = name.dropFirst("config.json.broken-".count)
                let isBackup = name.hasPrefix("config.json.broken-") && !suffix.isEmpty
                    && suffix.allSatisfy { $0.isASCII && $0.isNumber }
                if name == "config.json.tmp" || isBackup { try fm.removeItem(at: url) }
            }
        } catch {
            throw ConfigStoreError.cleanupFailed
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ConfigStoreError.invalidConfiguration }
    }

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    /// Explicit allowlist: credentials can never be encoded into the settings file.
    private struct StoredConfig: Codable {
        let schemaVersion: Int
        let credentialReference: String
        var retiredCredentialReferences: [String]?
        let username: String
        let gateway: String
        let serverCertPin: String
        let openconnectPath: String
        let vpncScriptPath: String
        let skipDNSModification: Bool
        let otpSentSeparately: Bool?
        let userAgent: String?
        let resolverRules: [ResolverRule]?

        init(config: VPNConfig, reference: String) {
            schemaVersion = 3
            credentialReference = reference
            username = config.username
            gateway = config.gateway
            serverCertPin = config.serverCertPin
            openconnectPath = config.openconnectPath
            vpncScriptPath = config.vpncScriptPath
            skipDNSModification = config.skipDNSModification
            otpSentSeparately = config.otpSentSeparately
            userAgent = config.userAgent
            resolverRules = config.resolverRules
        }

        func config(credentials: VPNCredentials) -> VPNConfig {
            VPNConfig(username: username, passwordPrefix: credentials.passwordPrefix,
                      totpSecret: credentials.totpSecret, gateway: gateway, serverCertPin: serverCertPin,
                      openconnectPath: openconnectPath, vpncScriptPath: vpncScriptPath,
                      skipDNSModification: skipDNSModification, otpSentSeparately: otpSentSeparately,
                      userAgent: userAgent, resolverRules: resolverRules)
        }
    }
}
