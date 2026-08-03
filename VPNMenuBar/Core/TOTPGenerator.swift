import Foundation
import CryptoKit

enum TOTPError: Error, Equatable {
    case invalidBase32
    case invalidDigits
}

enum TOTPGenerator {
    static let step: TimeInterval = 30

    /// Seconds left before the current 30s step rolls over.
    ///
    /// A code minted in the tail of its step can be rejected by the gateway:
    /// the round trip (spawn openconnect → TLS → first auth form → second auth
    /// form → POST) takes long enough that the server may already be validating
    /// against the next step by the time the code arrives.
    static func secondsRemainingInStep(at date: Date = Date()) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: step)
        return Int((step - elapsed).rounded(.up))
    }

    /// Compute the TOTP code for the given Base32-encoded secret at the given time.
    /// Follows RFC 6238 with HMAC-SHA1, 30s step, configurable digit count.
    static func code(secret: String, at date: Date = Date(), digits: Int = 6) throws -> String {
        guard (1...9).contains(digits) else { throw TOTPError.invalidDigits }
        let key = try base32Decode(secret)
        let counter = UInt64(max(0, date.timeIntervalSince1970) / 30)

        var bigEndianCounter = counter.bigEndian
        let counterBytes = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }

        let hmac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterBytes,
            using: SymmetricKey(data: key)
        )
        let mac = Data(hmac)

        // Dynamic truncation (RFC 4226 §5.3).
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let binary =
            (UInt32(mac[offset])     & 0x7f) << 24 |
            (UInt32(mac[offset + 1]) & 0xff) << 16 |
            (UInt32(mac[offset + 2]) & 0xff) << 8  |
            (UInt32(mac[offset + 3]) & 0xff)

        let modulus = UInt32(pow(10.0, Double(digits)))
        let truncated = binary % modulus
        return String(format: "%0\(digits)u", truncated)
    }

    /// Decode an RFC 4648 Base32 string (uppercase, no padding required).
    static func base32Decode(_ input: String) throws -> Data {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        let cleaned = input
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: " ", with: "")

        var bits = 0
        var buffer: UInt32 = 0
        var output = Data()

        for char in cleaned {
            guard let index = alphabet.firstIndex(of: char) else {
                throw TOTPError.invalidBase32
            }
            let value = UInt32(alphabet.distance(from: alphabet.startIndex, to: index))
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return output
    }
}
