import Foundation

/// Walks the user through anything still needed for connect (CLI / TTY).
public enum InteractiveSetup {
    /// Ensure daemon is up and all credentials/privileges exist, prompting as needed.
    /// - Parameter force: Re-prompt for items that are already set.
    @discardableResult
    public static func ensureReady(
        client: DaemonClient = DaemonClient(autoStart: true),
        force: Bool = false
    ) throws -> IPCResponse {
        try DaemonLifecycle.ensureRunning()
        var status = try client.status()
        var needs = SetupNeeds.from(response: status)

        if needs.isReady && !force {
            return status
        }

        fputs("\n", stderr)
        fputs("UoA VPN setup\n", stderr)
        fputs("─────────────\n", stderr)
        if !needs.isReady {
            fputs("Missing: \(needs.missingSummary)\n\n", stderr)
        } else {
            fputs("Updating configuration…\n\n", stderr)
        }

        var config = VPNConfig.load()
        if let u = status.username, !u.isEmpty { config.username = u }
        if let s = status.server, !s.isEmpty { config.server = s }
        if let p = status.openconnectPath, !p.isEmpty { config.openconnectPath = p }
        if let pr = status.protocolName, !pr.isEmpty { config.protocolName = pr }

        // Username
        if needs.username || force {
            let user = try SecureInput.readLine(
                prompt: "University username (e.g. jgra818)",
                default: config.username.isEmpty ? nil : config.username
            )
            guard !user.isEmpty else {
                throw IPCError.commandFailed("Username is required.")
            }
            config.username = user
            let r = try client.setConfig(config)
            guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed to save username") }
            fputs("  ✓ username saved\n", stderr)
        }

        if (status.server ?? "") != VPNConfig.defaults.server {
            config.server = VPNConfig.defaults.server
            let r = try client.setConfig(config)
            guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed to normalize server") }
        }

        // Password
        if needs.password || force {
            if force && (status.hasPassword == true) {
                if try !SecureInput.confirm(prompt: "Replace existing VPN password?", defaultYes: false) {
                    // keep
                } else {
                    let password = try SecureInput.readSecret(prompt: "VPN password: ")
                    guard !password.isEmpty else {
                        throw IPCError.commandFailed("Password is required.")
                    }
                    let r = try client.setPassword(password)
                    guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed to save password") }
                    fputs("  ✓ password saved\n", stderr)
                }
            } else {
                let password = try SecureInput.readSecret(prompt: "VPN password: ")
                guard !password.isEmpty else {
                    throw IPCError.commandFailed("Password is required.")
                }
                let r = try client.setPassword(password)
                guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed to save password") }
                fputs("  ✓ password saved\n", stderr)
            }
        }

        // TOTP
        if needs.totp || force {
            if force && (status.hasTOTPSecret == true) {
                if try SecureInput.confirm(prompt: "Replace existing TOTP secret?", defaultYes: false) {
                    try promptAndSaveTOTP(client: client)
                }
            } else {
                fputs(
                    """
                    TOTP secret is the Base32 value from your authenticator QR
                    (the secret=… field in otpauth://…), not a 6-digit code.

                    """,
                    stderr
                )
                try promptAndSaveTOTP(client: client)
            }
        }

        // The packaged runtime is installed alongside the app/CLI, then copied into
        // a root-owned location by SudoersInstaller. Arbitrary executable paths are
        // deliberately unsupported at the privilege boundary.
        status = try client.status()
        needs = SetupNeeds.from(response: status)
        if needs.openconnect {
            throw IPCError.commandFailed(
                "Bundled openconnect runtime is missing. Run ./Scripts/build.sh and ./Scripts/install.sh."
            )
        }

        // Passwordless sudo
        status = try client.status()
        needs = SetupNeeds.from(response: status)
        if needs.sudo || force {
            if needs.sudo {
                fputs(
                    """

                    The VPN network setup needs root. Passwordless sudo is limited to
                    UoA Proxy's fixed validating helper and is required over SSH.

                    """,
                    stderr
                )
                if try SecureInput.confirm(prompt: "Install the privileged VPN helper now?", defaultYes: true) {
                    fputs("(Mac login password — input is hidden)\n", stderr)
                    try SudoersInstaller.install(openconnectPath: config.openconnectPath)
                    fputs("  ✓ privileged helper installed\n", stderr)
                } else {
                    throw IPCError.commandFailed(
                        "Passwordless sudo is required. Run: uoa-proxy install-sudo"
                    )
                }
            } else if force {
                fputs("  · passwordless sudo already OK\n", stderr)
            }
        }

        status = try client.status()
        needs = SetupNeeds.from(response: status)
        if !needs.isReady {
            throw IPCError.commandFailed("Setup still incomplete: \(needs.missingSummary)")
        }

        fputs("\nSetup complete.\n\n", stderr)
        return status
    }

    private static func promptAndSaveTOTP(client: DaemonClient) throws {
        while true {
            let secret = try SecureInput.readSecret(prompt: "TOTP Base32 secret: ")
            let cleaned = TOTPGenerator.normalizeSecret(secret)
            guard !cleaned.isEmpty else {
                throw IPCError.commandFailed("TOTP secret is required.")
            }
            do {
                let code = try TOTPGenerator.generate(secretBase32: cleaned)
                let r = try client.setTOTPSecret(cleaned)
                guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed to save TOTP") }
                fputs("  ✓ TOTP secret saved (current code \(code))\n", stderr)
                return
            } catch let error as TOTPError {
                fputs("  Invalid secret: \(error.localizedDescription). Try again.\n", stderr)
            }
        }
    }
}
