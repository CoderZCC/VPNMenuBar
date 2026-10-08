import Foundation
import CryptoKit
import Darwin

/// Local encryption only: processes running as this user can read both files.
final class LocalCredentialStore: CredentialStoring {
    private let directory: URL
    private let magic = Data("VMC1".utf8)

    init(baseDirectory: URL) {
        directory = baseDirectory.appendingPathComponent("local-credentials", isDirectory: true)
    }

    private func record(_ reference: String) throws -> URL {
        guard UUID(uuidString: reference) != nil else { throw CredentialStoreError.invalidData }
        return directory.appendingPathComponent(reference, isDirectory: true)
    }

    private func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { throw CredentialStoreError.missingLocalCredentials }
            throw CredentialStoreError.localStorageFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { throw CredentialStoreError.localStorageFailure }
    }

    private func readFile(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw CredentialStoreError.missingLocalCredentials }
            throw CredentialStoreError.localStorageFailure
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
              info.st_size <= 1_048_576 else { throw CredentialStoreError.localStorageFailure }
        return try handle.readToEnd() ?? Data()
    }

    private func writeFile(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CredentialStoreError.localStorageFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func read(reference: String) throws -> VPNCredentials {
        let folder = try record(reference)
        try checkDirectory(directory)
        try checkDirectory(folder)
        let key = try readFile(folder.appendingPathComponent("key"))
        let payload = try readFile(folder.appendingPathComponent("sealed"))
        guard key.count == 32, payload.starts(with: magic) else { throw CredentialStoreError.invalidData }
        do {
            let box = try AES.GCM.SealedBox(combined: payload.dropFirst(magic.count))
            let data = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(reference.utf8))
            return try JSONDecoder().decode(VPNCredentials.self, from: data)
        } catch { throw CredentialStoreError.invalidData }
    }

    func add(_ credentials: VPNCredentials, reference: String) throws {
        let folder = try record(reference)
        // mkdir is exclusive; a pre-existing key is never silently regenerated or overwritten.
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw CredentialStoreError.localStorageFailure }
        try checkDirectory(directory)
        guard mkdir(folder.path, 0o700) == 0 else { throw CredentialStoreError.localStorageFailure }
        do {
            let key = SymmetricKey(size: .bits256)
            let box = try AES.GCM.seal(JSONEncoder().encode(credentials), using: key, authenticating: Data(reference.utf8))
            guard let combined = box.combined else { throw CredentialStoreError.invalidData }
            try writeFile(key.withUnsafeBytes { Data($0) }, to: folder.appendingPathComponent("key"))
            try writeFile(magic + combined, to: folder.appendingPathComponent("sealed"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func delete(reference: String) throws {
        let folder = try record(reference)
        do {
            try checkDirectory(directory)
            try checkDirectory(folder)
        } catch CredentialStoreError.missingLocalCredentials { return }
        try FileManager.default.removeItem(at: folder)
    }
}
