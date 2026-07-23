import Foundation

/// What's still missing before a VPN connect can succeed.
public struct SetupNeeds: Sendable, Equatable {
    public var username: Bool
    public var password: Bool
    public var totp: Bool
    public var sudo: Bool
    public var openconnect: Bool

    public init(
        username: Bool = false,
        password: Bool = false,
        totp: Bool = false,
        sudo: Bool = false,
        openconnect: Bool = false
    ) {
        self.username = username
        self.password = password
        self.totp = totp
        self.sudo = sudo
        self.openconnect = openconnect
    }

    public var isReady: Bool {
        !username && !password && !totp && !sudo && !openconnect
    }

    public var missingSummary: String {
        var parts: [String] = []
        if username { parts.append("username") }
        if password { parts.append("password") }
        if totp { parts.append("TOTP secret") }
        if sudo { parts.append("passwordless sudo") }
        if openconnect { parts.append("openconnect binary") }
        return parts.joined(separator: ", ")
    }

    public static func from(response r: IPCResponse) -> SetupNeeds {
        let openconnectMissing = !(r.sudoOK ?? false)
            && AppPaths.resolveOpenconnectRuntimeSource() == nil
        return SetupNeeds(
            username: (r.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            password: !(r.hasPassword ?? false),
            totp: !(r.hasTOTPSecret ?? false),
            sudo: !(r.sudoOK ?? false),
            openconnect: openconnectMissing
        )
    }

    public static func fromLocalFiles() -> SetupNeeds {
        let config = VPNConfig.load()
        let password = (try? KeychainStore.load(account: .password)) ?? ""
        let totp = (try? KeychainStore.load(account: .totpSecret)) ?? ""
        return SetupNeeds(
            username: config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            password: password.isEmpty,
            totp: TOTPGenerator.normalizeSecret(totp).isEmpty,
            sudo: !SudoersInstaller.isPasswordlessSudoAvailable(),
            openconnect: !SudoersInstaller.isPasswordlessSudoAvailable()
                && AppPaths.resolveOpenconnectRuntimeSource() == nil
        )
    }
}
