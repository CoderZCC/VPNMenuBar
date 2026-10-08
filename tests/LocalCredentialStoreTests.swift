import Foundation

@main
struct LocalCredentialStoreTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    static func fails(_ body: () throws -> Void) {
        do { try body() } catch { return }
        fatalError("Expected failure")
    }
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let credentials = LocalCredentialStore(baseDirectory: dir)
        let store = ConfigStore(baseDirectory: dir, credentials: credentials)
        var config = VPNConfig(username: "fixture", passwordPrefix: "synthetic-password", totpSecret: "SYNTHETIC-TOTP")
        config.gateway = "vpn.example.com"
        config.serverCertPin = "fixture-pin"
        let plaintext = try JSONEncoder().encode(config)
        try plaintext.write(to: store.configURL)
        try require(store.load() == config, "Plaintext migration")
        let reload = ConfigStore(baseDirectory: dir, credentials: LocalCredentialStore(baseDirectory: dir))
        try require(reload.load() == config, "Independent instance decrypts after restart")
        let json = try Data(contentsOf: store.configURL)
        let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        try require(object["schemaVersion"] as? Int == 3, "Distinct local format")
        let reference = object["credentialReference"] as! String
        let records = dir.appendingPathComponent("local-credentials")
        let record = records.appendingPathComponent(reference)
        let key = record.appendingPathComponent("key")
        let sealed = record.appendingPathComponent("sealed")
        let payload = try Data(contentsOf: sealed)
        for url in [store.configURL, key, sealed] {
            let data = try Data(contentsOf: url)
            try require(data.range(of: Data(config.passwordPrefix.utf8)) == nil && data.range(of: Data(config.totpSecret.utf8)) == nil, "No plaintext on disk")
            let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            try require(mode.intValue == 0o600, "Private file mode")
        }
        for url in [records, record] {
            let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            try require(mode.intValue == 0o700, "Private directory mode")
        }
        print("PASS: plaintext-to-local migration, unsigned restart decryption, secret-free settings, private files")

        var changed = payload
        changed[changed.count - 1] ^= 1
        try changed.write(to: sealed)
        fails { _ = try reload.load() }
        fails { try reload.save(config) }
        try require(Data(contentsOf: store.configURL) == json, "Tampering must preserve settings")
        try payload.write(to: sealed)
        let another = UUID().uuidString
        try fm.copyItem(at: record, to: records.appendingPathComponent(another))
        fails { _ = try credentials.read(reference: another) }
        try credentials.delete(reference: another)
        fails { _ = try credentials.read(reference: "../../escape") }
        try fm.removeItem(at: key)
        fails { _ = try reload.load() }
        fails { try reload.save(config) }
        try require(!fm.fileExists(atPath: key.path), "Missing key must not be regenerated")
        config.passwordPrefix = "replacement-password"
        try reload.save(config, replacingMissingCredentials: true)
        try require(reload.load() == config && !fm.fileExists(atPath: record.path), "Explicit missing-key recovery retires old record")
        print("PASS: authentication/tag/reference guards, missing-key preservation and explicit recovery")

        let legacyDir = dir.appendingPathComponent("legacy-keychain")
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyStore = ConfigStore(baseDirectory: legacyDir, credentials: LocalCredentialStore(baseDirectory: legacyDir))
        var old = object
        old["schemaVersion"] = 2
        let legacy = try JSONSerialization.data(withJSONObject: old)
        try legacy.write(to: legacyStore.configURL)
        fails { _ = try legacyStore.load() }
        fails { try legacyStore.save(config) }
        try require(Data(contentsOf: legacyStore.configURL) == legacy, "Keychain schema must not be reinterpreted")
        try require(legacyStore.loadSettings()?.username == config.username, "Legacy settings available for re-entry")
        try legacyStore.save(config, replacingMissingCredentials: true)
        try require(legacyStore.load() == config, "Explicit legacy Keychain format replacement")
        print("PASS: legacy Keychain format preserved until explicit credential re-entry")

        let failDir = dir.appendingPathComponent("blocked")
        try fm.createDirectory(at: failDir, withIntermediateDirectories: true)
        let blocked = ConfigStore(baseDirectory: failDir, credentials: LocalCredentialStore(baseDirectory: failDir))
        try plaintext.write(to: blocked.configURL)
        try fm.createSymbolicLink(at: failDir.appendingPathComponent("local-credentials"), withDestinationURL: records)
        fails { _ = try blocked.load() }
        try require(Data(contentsOf: blocked.configURL) == plaintext, "Failed encrypted migration preserves plaintext")
        print("PASS: symlink storage rejection and migration failure preservation")
    }
}
