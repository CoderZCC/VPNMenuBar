import Foundation
import Security

struct VPNCredentials: Codable, Equatable {
    let passwordPrefix: String
    let totpSecret: String
}

protocol CredentialStoring {
    func read(reference: String) throws -> VPNCredentials
    func add(_ credentials: VPNCredentials, reference: String) throws
    func delete(reference: String) throws
}

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidData
    case missingLocalCredentials
    case localStorageFailure
    case legacyKeychainConfiguration

    var canReenterCredentials: Bool {
        switch self {
        case .missingLocalCredentials, .invalidData, .legacyKeychainConfiguration, .keychain(errSecItemNotFound): return true
        default: return false
        }
    }

    var isTemporarilyUnavailable: Bool {
        switch self {
        case .keychain(errSecInteractionNotAllowed), .keychain(errSecNotAvailable): return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingLocalCredentials:
            return "The encrypted credentials or their local key are missing. Re-enter credentials in Settings."
        case .localStorageFailure:
            return "Local credential storage could not be accessed securely. Check folder ownership and permissions."
        case .legacyKeychainConfiguration:
            return "This configuration uses the previous Keychain format. Re-enter credentials in Settings to switch to local encryption. The original configuration is preserved until you save."
        case .keychain(errSecItemNotFound):
            return "VPN credentials are missing from Keychain. Open Settings to re-enter them on this Mac."
        case .keychain(errSecMissingEntitlement):
            return "This build cannot access the protected Keychain. Use a signed build with a valid Keychain access entitlement."
        case .keychain(let status):
            return "Keychain access failed (\(status)). Unlock your Mac and try again."
        case .invalidData:
            return "The saved credentials could not be verified. Re-enter them in Settings. The existing configuration is preserved until you save."
        }
    }
}
