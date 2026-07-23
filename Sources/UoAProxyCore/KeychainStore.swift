import Foundation
import Security

/// Stores VPN password and TOTP secret.
///
/// Primary storage is a mode-0600 file under Application Support so the
/// daemon and SSH sessions work without Keychain UI (Keychain returns
/// `errSecInteractionNotAllowed` / -25308 over SSH and for non-Aqua daemons).
///
/// On load, any legacy Keychain items are migrated into the file once.
public enum KeychainStore {
    public enum Account: String, Codable {
        case password = "vpn-password"
        case totpSecret = "totp-secret"
    }

    private struct SecretsFile: Codable {
        var password: String?
        var totpSecret: String?
    }

    private static let fileURL = AppPaths.supportDirectory.appendingPathComponent("secrets.json")

    public static func save(_ value: String, account: Account) throws {
        var secrets = loadFile()
        switch account {
        case .password:
            secrets.password = value.isEmpty ? nil : value
        case .totpSecret:
            secrets.totpSecret = value.isEmpty ? nil : value
        }
        try writeFile(secrets)
        // Best-effort remove legacy Keychain copy so we don't leave two sources of truth
        try? deleteFromKeychain(account: account)
    }

    public static func load(account: Account) throws -> String? {
        // Prefer file
        let secrets = loadFile()
        let fromFile: String?
        switch account {
        case .password:
            fromFile = secrets.password
        case .totpSecret:
            fromFile = secrets.totpSecret
        }
        if let fromFile, !fromFile.isEmpty {
            return fromFile
        }

        // Migrate from Keychain if present (may fail over SSH — ignore)
        if let legacy = try? loadFromKeychain(account: account), !legacy.isEmpty {
            try? save(legacy, account: account)
            return legacy
        }
        return nil
    }

    public static func delete(account: Account) throws {
        var secrets = loadFile()
        switch account {
        case .password:
            secrets.password = nil
        case .totpSecret:
            secrets.totpSecret = nil
        }
        try writeFile(secrets)
        try? deleteFromKeychain(account: account)
    }

    // MARK: - File

    private static func loadFile() -> SecretsFile {
        guard let data = try? Data(contentsOf: fileURL),
              let secrets = try? JSONDecoder().decode(SecretsFile.self, from: data) else {
            return SecretsFile()
        }
        return secrets
    }

    private static func writeFile(_ secrets: SecretsFile) throws {
        try FileManager.default.createDirectory(
            at: AppPaths.supportDirectory,
            withIntermediateDirectories: true
        )
        // Directory owner-only
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: AppPaths.supportDirectory.path
        )

        // Empty both → remove file
        if (secrets.password == nil || secrets.password?.isEmpty == true)
            && (secrets.totpSecret == nil || secrets.totpSecret?.isEmpty == true) {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(secrets)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    // MARK: - Legacy Keychain (migration only)

    private static func loadFromKeychain(account: Account) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppPaths.serviceName,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound || status == errSecInteractionNotAllowed {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteFromKeychain(account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppPaths.serviceName,
            kSecAttrAccount as String: account.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound
                || status == errSecInteractionNotAllowed else {
            throw KeychainError.unhandled(status)
        }
    }
}

public enum KeychainError: LocalizedError {
    case unhandled(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Secret store error (\(status)): \(message)"
        }
    }
}
