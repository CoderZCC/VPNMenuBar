import Foundation
import Security

private enum TestError: Error { case injected }

private final class MemoryCredentials: CredentialStoring {
    var items: [String: VPNCredentials] = [:]
    var failAdd = false
    var failRead = false
    var failDelete = false
    var corruptRead = false
    var afterAdd: (() throws -> Void)?
    func read(reference: String) throws -> VPNCredentials {
        if failRead { throw CredentialStoreError.keychain(errSecInteractionNotAllowed) }
        guard let item = items[reference] else { throw CredentialStoreError.keychain(errSecItemNotFound) }
        return corruptRead ? VPNCredentials(passwordPrefix: "wrong", totpSecret: "wrong") : item
    }
    func add(_ credentials: VPNCredentials, reference: String) throws {
        if failAdd { throw TestError.injected }
        items[reference] = credentials
        try afterAdd?()
    }
    func delete(reference: String) throws {
        if failDelete { throw TestError.injected }
        items.removeValue(forKey: reference)
    }
}

@main
struct ConfigStoreTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { fatalError(message) }
    }

    static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        fatalError("Expected failure")
    }

    private static func fixture(_ test: (URL, MemoryCredentials, ConfigStore, VPNConfig) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = MemoryCredentials()
        let store = ConfigStore(baseDirectory: directory, credentials: credentials)
        var config = VPNConfig(username: "fixture-user", passwordPrefix: "fixture-password", totpSecret: "FIXTURE-SECRET")
        config.gateway = "vpn.example.com"
        config.serverCertPin = "fixture-pin"
        config.otpSentSeparately = true
        config.userAgent = "fixture-agent"
        config.resolverRules = [ResolverRule(domain: "intranet.example.com", nameserver: "10.0.0.53")]
        try test(directory, credentials, store, config)
    }

    static func main() throws {
        try fixture { directory, credentials, store, config in
            try expect(store.load() == nil, "New installation")
            try store.save(config)
            try expect(store.load() == config, "All settings and credentials must round trip")
            let json = try String(contentsOf: store.configURL, encoding: .utf8)
            for forbidden in ["passwordPrefix", "totpSecret", config.passwordPrefix, config.totpSecret] {
                try expect(!json.contains(forbidden), "Settings must contain no credential fields or values")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: store.configURL.path)
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Settings mode")
            var edited = config
            edited.username = "another-user"
            edited.passwordPrefix = "new-password"
            try store.save(edited)
            try expect(store.load() == edited, "Credential replacement")
            try expect(credentials.items.count == 1, "Old credentials removed after commit")
            try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"], "No temp files")
        }
        print("PASS: new save, secret-free JSON, permissions, update")
        try fixture { directory, credentials, store, config in
            let legacy = try JSONEncoder().encode(config)
            try legacy.write(to: store.configURL)
            try legacy.write(to: directory.appendingPathComponent("config.json.tmp"))
            try legacy.write(to: directory.appendingPathComponent("config.json.broken-123"))
            try Data("keep".utf8).write(to: directory.appendingPathComponent("unrelated.txt"))
            try expect(store.load() == config, "Legacy migration")
            try expect(credentials.items.count == 1, "Migration writes one item")
            try expect(store.load() == config && credentials.items.count == 1, "Migration is idempotent")
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try expect(Set(names) == Set(["config.json", "unrelated.txt"]), "Only legacy copies removed")
        }
        print("PASS: migration, idempotence, legacy copy cleanup")
        for mode in ["add", "verify"] {
            try fixture { _, credentials, store, config in
                let legacy = try JSONEncoder().encode(config)
                try legacy.write(to: store.configURL)
                credentials.failAdd = mode == "add"
                credentials.corruptRead = mode == "verify"
                try expectFailure { _ = try store.load() }
                try expect(Data(contentsOf: store.configURL) == legacy, "Failed migration preserves legacy bytes")
                try expect(credentials.items.isEmpty, "Failed verification rolls back new item")
            }
        }
        print("PASS: failed credential store write and verification preserve legacy config")
        try fixture { _, credentials, store, config in
            try store.save(config)
            let original = try Data(contentsOf: store.configURL)
            let originalItems = credentials.items
            credentials.failRead = true
            try expect(store.hasConfiguration, "Locked credential store is not new installation")
            try expect(store.loadSettings()?.gateway == config.gateway, "Dependency checks work without secrets")
            try expect(store.loadSettings()?.passwordPrefix == "", "Dependency checks get no secrets")
            try expectFailure { _ = try store.load() }
            try expectFailure { try store.save(config) }
            try expectFailure { try store.save(config, replacingMissingCredentials: true) }
            try expect(Data(contentsOf: store.configURL) == original, "Locked credential store preserves config")
            try expect(credentials.items == originalItems, "Locked credential store preserves credentials")
            credentials.failRead = false
            credentials.items = [:]
            try expectFailure { _ = try store.load() }
            try expect(Data(contentsOf: store.configURL) == original, "Missing credentials preserve config")
            try expectFailure { try store.save(config) }
            try store.save(config, replacingMissingCredentials: true)
            try expect(store.load() == config, "Explicit recovery can recreate missing credentials")
        }
        print("PASS: locked/missing credential store, metadata-only dependency checks")
        try fixture { directory, credentials, store, config in
            try store.save(config)
            let original = try Data(contentsOf: store.configURL)
            let originalItems = credentials.items
            // Make the destination unwritable after credential store succeeds.
            credentials.afterAdd = { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path) }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            try expectFailure { try store.save(config) }
            try expect(Data(contentsOf: store.configURL) == original, "JSON write failure preserves old config")
            try expect(credentials.items == originalItems, "JSON write failure preserves old credentials")
        }
        print("PASS: JSON commit failure rollback")
        try fixture { _, credentials, store, config in
            try store.save(config)
            credentials.failDelete = true
            var updated = config
            updated.passwordPrefix = "updated-password"
            try expectFailure { try store.save(updated) }
            try expect(credentials.items.count == 2, "Old item retained until cleanup succeeds")
            credentials.failDelete = false
            try expect(store.load() == updated, "Committed config remains readable after cleanup failure")
            try expect(credentials.items.count == 1, "Cleanup is retried after interruption")
        }
        print("PASS: failed cleanup is recoverable")
        try fixture { _, credentials, store, config in
            for invalid in ["{broken", "{\"schemaVersion\":99}", "{\"schemaVersion\":1}"] {
                let data = Data(invalid.utf8)
                try data.write(to: store.configURL)
                try expectFailure { _ = try store.load() }
                try expectFailure { try store.save(config) }
                try expect(Data(contentsOf: store.configURL) == data, "Unreadable config must not be replaced")
                try expect(credentials.items.isEmpty, "Invalid config must not alter credential store")
            }
        }
        print("PASS: invalid and unsupported configs remain untouched")
        try fixture { directory, credentials, store, config in
            let broken = Data("{broken-fixture-secret".utf8)
            try broken.write(to: store.configURL)
            try store.recoverUnreadableConfiguration()
            try expect(!store.hasConfiguration, "Explicit recovery allows new setup")
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            try expect(backups.count == 1, "Preserve original corrupt file")
            try expect(Data(contentsOf: backups[0]) == broken, "Recovery preserves exact original bytes")
            let attrs = try FileManager.default.attributesOfItem(atPath: backups[0].path)
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Recovery file is private")
            credentials.failAdd = true
            try expectFailure { try store.save(config) }
            try expect(FileManager.default.fileExists(atPath: backups[0].path), "Keep original until save succeeds")
            credentials.failAdd = false
            try store.save(config)
            try expect(store.load() == config, "Fresh settings work after recovery")
            try expect(!FileManager.default.fileExists(atPath: backups[0].path), "Remove old plaintext after save")
            let saved = try Data(contentsOf: store.configURL)
            try expectFailure { try store.recoverUnreadableConfiguration() }
            try expect(Data(contentsOf: store.configURL) == saved, "Cannot reset readable config")
            credentials.failRead = true
            try expectFailure { try store.recoverUnreadableConfiguration() }
            try expect(Data(contentsOf: store.configURL) == saved, "Locked credential store is not corrupt config")
        }
        print("PASS: explicit corrupt-file recovery, backup lifecycle, readable/locked reset guard")
    }
}
