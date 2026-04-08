import Foundation
import AppKit
import Vision

enum QRExtractError: Error, LocalizedError, Equatable {
    case imageLoadFailed
    case noQRCodeFound
    case notOtpauthURI
    case missingSecret
    case invalidBase32

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed:
            return "Could not read the selected file as an image."
        case .noQRCodeFound:
            return "No QR code was found in this image."
        case .notOtpauthURI:
            return "The QR code is not a TOTP otpauth URI."
        case .missingSecret:
            return "The otpauth URI does not contain a secret parameter."
        case .invalidBase32:
            return "The secret in the QR code is not valid Base32."
        }
    }
}

struct OTPAuthInfo: Equatable {
    let secret: String
    let account: String?
}

enum QRCodeSecretExtractor {
    /// Load the image at `url`, find a QR code, parse it as an otpauth://totp URI,
    /// and return the validated Base32 `secret` plus an optional `account` derived
    /// from the URI label. Synchronous — call from a background Task.
    static func extract(fromImageAt url: URL) throws -> OTPAuthInfo {
        guard
            let nsImage = NSImage(contentsOf: url),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw QRExtractError.imageLoadFailed
        }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw QRExtractError.noQRCodeFound
        }

        guard
            let observation = request.results?.first,
            let payload = observation.payloadStringValue
        else {
            throw QRExtractError.noQRCodeFound
        }

        guard
            let components = URLComponents(string: payload),
            components.scheme?.lowercased() == "otpauth",
            components.host?.lowercased() == "totp"
        else {
            throw QRExtractError.notOtpauthURI
        }

        guard
            let rawSecret = components.queryItems?
                .first(where: { $0.name.lowercased() == "secret" })?
                .value,
            !rawSecret.isEmpty
        else {
            throw QRExtractError.missingSecret
        }

        do {
            _ = try TOTPGenerator.base32Decode(rawSecret)
        } catch {
            throw QRExtractError.invalidBase32
        }

        let account = parseAccount(from: components.path)
        return OTPAuthInfo(secret: rawSecret, account: account)
    }

    /// Parse the account name from the otpauth URI path component.
    /// Returns nil when the result is empty after normalization.
    private static func parseAccount(from rawPath: String) -> String? {
        var label = rawPath
        if label.hasPrefix("/") { label.removeFirst() }
        guard let decoded = label.removingPercentEncoding else { return nil }

        var account = decoded
        if let colonIndex = account.firstIndex(of: ":") {
            account = String(account[account.index(after: colonIndex)...])
        }
        if let atIndex = account.firstIndex(of: "@") {
            account = String(account[..<atIndex])
        }

        let trimmed = account.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
