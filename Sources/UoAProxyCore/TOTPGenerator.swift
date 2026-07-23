import Foundation
import CryptoKit

/// RFC 6238 TOTP generator (HMAC-SHA1, 30s step, 6 digits by default).
public enum TOTPGenerator {
    public static func generate(
        secretBase32: String,
        date: Date = Date(),
        period: TimeInterval = 30,
        digits: Int = 6
    ) throws -> String {
        let secret = try decodeBase32(secretBase32)
        let counter = UInt64(floor(date.timeIntervalSince1970 / period))
        var bigEndian = counter.bigEndian
        let counterData = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)

        let key = SymmetricKey(data: secret)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hash = Data(mac)

        let offset = Int(hash[hash.count - 1] & 0x0f)
        let binary =
            (Int(hash[offset] & 0x7f) << 24)
            | (Int(hash[offset + 1] & 0xff) << 16)
            | (Int(hash[offset + 2] & 0xff) << 8)
            | Int(hash[offset + 3] & 0xff)

        let modulus = Int(pow(10.0, Double(digits)))
        let otp = binary % modulus
        return String(format: "%0\(digits)d", otp)
    }

    public static func secondsRemaining(date: Date = Date(), period: TimeInterval = 30) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return max(1, Int(ceil(period - elapsed)))
    }

    public static func normalizeSecret(_ raw: String) -> String {
        raw.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase32(_ input: String) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let cleaned = normalizeSecret(input)

        guard !cleaned.isEmpty else {
            throw TOTPError.emptySecret
        }

        var bits = 0
        var value = 0
        var output = Data()

        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else {
                throw TOTPError.invalidBase32
            }
            value = (value << 5) | alphabet.distance(from: alphabet.startIndex, to: index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((value >> bits) & 0xff))
            }
        }

        guard !output.isEmpty else {
            throw TOTPError.invalidBase32
        }
        return output
    }
}

public enum TOTPError: LocalizedError {
    case emptySecret
    case invalidBase32

    public var errorDescription: String? {
        switch self {
        case .emptySecret:
            return "TOTP secret is empty."
        case .invalidBase32:
            return "TOTP secret is not valid Base32."
        }
    }
}
