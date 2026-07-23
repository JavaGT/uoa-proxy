import Darwin
import Foundation
import UoAProxyCore

@main
enum UoAProxyCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        // Bare `uoa-proxy` → setup if needed, then status (friendly first run)
        if args.isEmpty {
            do {
                try cmdDefault()
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }

        let command = args[0]
        do {
            try dispatch(command: command, args: Array(args.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func dispatch(command: String, args: [String]) throws {
        switch command {
        case "help", "-h", "--help":
            printUsage()

        case "setup", "init", "configure":
            try cmdSetup(force: args.contains("--force") || args.contains("-f"))

        case "status", "st":
            try cmdStatus()

        case "connect", "up":
            try cmdConnect()

        case "disconnect", "down":
            try cmdDisconnect()

        case "toggle":
            try cmdToggle()

        case "otp", "code", "2fa":
            try cmdOTP()

        case "config":
            try cmdConfig(args)

        case "daemon":
            try cmdDaemon(args)

        case "install-sudo":
            try cmdInstallSudo()

        case "logs":
            try cmdLogs(args)

        case "check-smb", "smb-check":
            try cmdCheckSMB()

        case "ui", "app", "gui", "menubar", "toolbar":
            try cmdUI()

        default:
            fputs("Unknown command: \(command)\n\n", stderr)
            printUsage()
            exit(1)
        }
    }

    // MARK: - Commands

    private static func client() -> DaemonClient {
        DaemonClient(autoStart: true)
    }

    /// First-run friendly entry when no subcommand is given.
    private static func cmdDefault() throws {
        try DaemonLifecycle.ensureRunning()
        var status = try client().status()
        let needs = SetupNeeds.from(response: status)
        if !needs.isReady {
            fputs("Welcome — a few things are needed before connecting.\n", stderr)
            status = try InteractiveSetup.ensureReady(client: client(), force: false)
            fputs("You can connect with: uoa-proxy connect\n\n", stderr)
        }
        printStatus(status)
        if status.state != .connected {
            fputs("\nTip: uoa-proxy connect\n", stderr)
        }
    }

    private static func cmdSetup(force: Bool) throws {
        _ = try InteractiveSetup.ensureReady(client: client(), force: force)
        let r = try client().status()
        printStatus(r)
    }

    private static func cmdStatus() throws {
        let r = try client().status()
        printStatus(r)
        let needs = SetupNeeds.from(response: r)
        if !needs.isReady {
            fputs("\nNot ready to connect (missing: \(needs.missingSummary)).\n", stderr)
            fputs("Run: uoa-proxy setup   or   uoa-proxy connect\n", stderr)
            exit(1)
        }
    }

    private static func cmdConnect() throws {
        _ = try InteractiveSetup.ensureReady(client: client(), force: false)
        fputs("Connecting… (this may take up to ~60s)\n", stderr)
        let r = try client().connect()
        printStatus(r)
        if r.state == .connected {
            fputs("Connected.\n", stderr)
            return
        }
        if let err = r.error, !err.isEmpty {
            fputs("\nConnect failed: \(err)\n", stderr)
        } else {
            fputs("\nConnect failed (state: \(r.state.rawValue)).\n", stderr)
        }
        fputs("VPN log: uoa-proxy logs vpn\n", stderr)
        fputs("Daemon:  uoa-proxy logs daemon\n", stderr)
        exit(1)
    }

    private static func cmdDisconnect() throws {
        fputs("Disconnecting…\n", stderr)
        let r = try client().disconnect()
        printStatus(r)
        if r.state != .disconnected {
            exit(1)
        }
    }

    private static func cmdToggle() throws {
        let status = try client().status()
        if status.state == .connected || status.state == .connecting {
            try cmdDisconnect()
        } else {
            try cmdConnect()
        }
    }

    private static func cmdOTP() throws {
        var r = try client().otp()
        if r.hasTOTPSecret != true {
            fputs("No TOTP secret yet — setting one up.\n", stderr)
            _ = try InteractiveSetup.ensureReady(client: client(), force: false)
            r = try client().otp()
        }
        if let otp = r.otp, otp != "------" {
            print(otp)
            if let sec = r.otpSecondsRemaining {
                fputs("(valid ~\(sec)s)\n", stderr)
            }
        } else {
            fputs("No TOTP secret configured.\n", stderr)
            exit(1)
        }
    }

    private static func cmdConfig(_ args: [String]) throws {
        guard let sub = args.first else {
            let r = try client().getConfig()
            print(
                """
                username:        \(r.username ?? "")
                server:          \(r.server ?? "")
                password set:    \(r.hasPassword == true ? "yes" : "no")
                totp secret set: \(r.hasTOTPSecret == true ? "yes" : "no")
                passwordless sudo: \(r.sudoOK == true ? "yes" : "no")
                """
            )
            let needs = SetupNeeds.from(response: r)
            if !needs.isReady {
                fputs("\nMissing: \(needs.missingSummary)\n", stderr)
                fputs("Run: uoa-proxy setup\n", stderr)
            }
            return
        }

        switch sub {
        case "set":
            guard args.count >= 2 else {
                fputs("Usage: uoa-proxy config set <user|password|totp> [value]\n", stderr)
                exit(1)
            }
            let key = args[1]
            let value = args.count >= 3 ? args[2] : nil
            try configSet(key: key, value: value)

        case "show":
            try cmdConfig([])

        default:
            fputs("Usage: uoa-proxy config [set …]\n", stderr)
            exit(1)
        }
    }

    private static func configSet(key: String, value: String?) throws {
        let c = client()
        switch key {
        case "user", "username":
            let user: String
            if let value, !value.isEmpty {
                user = value
            } else {
                user = try SecureInput.readLine(prompt: "University username (e.g. jgra818)")
            }
            guard !user.isEmpty else {
                fputs("Username is required.\n", stderr)
                exit(1)
            }
            var cfg = VPNConfig.load()
            cfg.username = user
            let r = try c.setConfig(cfg)
            guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed") }
            print("username = \(user)")

        case "password", "pass":
            let password: String
            if let value {
                password = value
            } else {
                password = try SecureInput.readSecret(prompt: "VPN password: ")
            }
            let r = try c.setPassword(password)
            guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed") }
            print("password saved")

        case "totp", "totp-secret", "secret":
            let secret: String
            if let value {
                secret = value
            } else {
                secret = try SecureInput.readSecret(prompt: "TOTP Base32 secret: ")
            }
            let r = try c.setTOTPSecret(secret)
            guard r.ok else { throw IPCError.commandFailed(r.error ?? "failed") }
            print("TOTP secret saved")

        default:
            fputs("Unknown config key: \(key)\n", stderr)
            exit(1)
        }
    }

    private static func cmdDaemon(_ args: [String]) throws {
        let sub = args.first ?? "status"
        switch sub {
        case "status":
            if DaemonLifecycle.isSocketLive() {
                let r = try DaemonClient(autoStart: false).status()
                print("daemon: running (pid \(r.daemonPID.map(String.init) ?? "?"))")
                print("socket: \(AppPaths.socketURL.path)")
                print("vpn:    \(r.state.rawValue) — \(r.message)")
            } else {
                print("daemon: not running")
                print("socket: \(AppPaths.socketURL.path) (missing)")
                exit(1)
            }

        case "start":
            try DaemonLifecycle.ensureRunning()
            if DaemonLifecycle.isSocketLive() {
                print("daemon started")
                return
            }
            throw IPCError.daemonUnavailable("socket never appeared")

        case "stop":
            do {
                try DaemonLifecycle.stopDaemon()
                print("daemon stopped")
            } catch {
                fputs("daemon stop incomplete: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "restart":
            try? DaemonLifecycle.stopDaemon()
            Thread.sleep(forTimeInterval: 0.3)
            try cmdDaemon(["start"])

        default:
            fputs("Usage: uoa-proxy daemon [status|start|stop|restart]\n", stderr)
            exit(1)
        }
    }

    private static func cmdInstallSudo() throws {
        print("Installing the fixed privileged VPN helper and bundled OpenConnect runtime…")
        print("(Your Mac password will be requested next; characters will not be shown.)")
        try SudoersInstaller.install()
        if SudoersInstaller.isPasswordlessSudoAvailable() {
            print("OK — the fixed helper probe succeeds. You can now: uoa-proxy connect")
        } else {
            print("Installed, but passwordless openconnect still fails. Check /etc/sudoers.d/uoa-proxy")
            exit(1)
        }
    }

    /// Launch the optional menu bar UI (does not go through the daemon).
    /// Needs a desktop/Aqua session — fails over plain SSH the same way `open` does.
    private static func cmdUI() throws {
        // Ensure daemon is up so the UI has something to talk to.
        try DaemonLifecycle.ensureRunning()

        guard let appPath = AppPaths.resolveMenuBarApp() else {
            fputs(
                """
                Menu bar app not found. Install with:
                  ./Scripts/install.sh
                Expected at: /Applications/UoA Proxy.app

                """,
                stderr
            )
            exit(1)
        }

        // Prefer `open` so macOS activates/reuses an existing instance.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appPath]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            // Fall through to direct exec attempt.
        }

        if open.terminationStatus == 0 {
            print("Opened menu bar app: \(appPath)")
            print("Quit from the menu (✕ or “Quit menu bar app”). VPN/daemon keep running.")
            return
        }

        // `open` often fails over SSH (OSLaunchdErrorDomain 125). Try binary directly
        // so local Desktop/Screen Sharing sessions still work without `open`.
        guard let bin = AppPaths.resolveMenuBarBinary() else {
            throw IPCError.commandFailed(
                "Could not launch UI (open exit \(open.terminationStatus)). Over SSH use Screen Sharing or a local Terminal; VPN stays on CLI: uoa-proxy status"
            )
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = []
        // Detach so CLI returns; UI is a separate process.
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            throw IPCError.commandFailed(
                "Could not launch \(bin): \(error.localizedDescription). Needs a desktop login session (not plain SSH)."
            )
        }
        print("Started menu bar binary: \(bin) (pid \(p.processIdentifier))")
        print("Quit from the menu (✕ or “Quit menu bar app”). VPN/daemon keep running.")
    }

    private static func cmdLogs(_ args: [String]) throws {
        let which = args.first ?? "daemon"
        let url: URL
        switch which {
        case "daemon", "d":
            url = AppPaths.daemonLogURL
        case "vpn", "openconnect", "oc":
            url = AppPaths.openconnectLogURL
        default:
            fputs("Usage: uoa-proxy logs [daemon|vpn]\n", stderr)
            exit(1)
        }
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            print(text)
        } else {
            print("(empty) \(url.path)")
        }
    }

    private static func cmdCheckSMB() throws {
        let host = "files.auckland.ac.nz"
        let status = try client().status()
        guard status.state == .connected else {
            throw IPCError.commandFailed("VPN is not connected. Run: uoa-proxy connect")
        }

        let dns = try runDiagnostic(
            "/usr/bin/dscacheutil",
            arguments: ["-q", "host", "-a", "name", host]
        )
        guard dns.status == 0, dns.output.contains("ip_address:") else {
            throw IPCError.commandFailed("University DNS did not resolve \(host). Check: uoa-proxy logs vpn")
        }

        let route = try runDiagnostic("/sbin/route", arguments: ["-n", "get", host])
        let interface = route.output.split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        guard route.status == 0, interface.hasPrefix("utun") else {
            throw IPCError.commandFailed(
                "\(host) is routed over \(interface), not the VPN. The gateway did not install the required SMB subnet route."
            )
        }

        let port = try runDiagnostic(
            "/usr/bin/nc",
            arguments: ["-G", "5", "-vz", host, "445"]
        )
        guard port.status == 0 else {
            throw IPCError.commandFailed("\(host):445 is unreachable over \(interface). \(port.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        print("SMB ready: \(host):445 resolves and routes over \(interface)")
        print("Finder: smb://files.auckland.ac.nz/research/resart202600017-studentworkandwellbeing")
    }

    private static func runDiagnostic(
        _ executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Helpers

    private static func printStatus(_ r: IPCResponse) {
        print("state:    \(r.state.rawValue)")
        print("message:  \(r.message)")
        if let user = r.username, !user.isEmpty {
            print("user:     \(user)")
        }
        if let server = r.server, !server.isEmpty {
            print("server:   \(server)")
        }
        if let otp = r.otp, r.hasTOTPSecret == true {
            print("otp:      \(otp)  (\(r.otpSecondsRemaining ?? 0)s)")
        }
        print("password: \(r.hasPassword == true ? "set" : "missing")")
        print("totp:     \(r.hasTOTPSecret == true ? "set" : "missing")")
        print("sudo -n:  \(r.sudoOK == true ? "ok" : "not configured")")
        if let pid = r.daemonPID {
            print("daemon:   pid \(pid)")
        }
        if let err = r.error, !err.isEmpty {
            print("error:    \(err)")
        }
    }

    private static func printUsage() {
        print(
            """
            uoa-proxy — control the UoA VPN daemon

            Usage:
              uoa-proxy                     Setup if needed, then show status
              uoa-proxy setup               Interactive setup (prompts for missing pieces)
              uoa-proxy setup --force       Re-enter everything
              uoa-proxy connect             Setup if needed, then connect
              uoa-proxy disconnect | toggle
              uoa-proxy status | otp
              uoa-proxy config
              uoa-proxy config set user|password|totp …
              uoa-proxy daemon status|start|stop|restart
              uoa-proxy ui                     Open menu bar app (desktop session)
              uoa-proxy install-sudo
              uoa-proxy check-smb              Verify research-drive DNS, route, and TCP 445
              uoa-proxy logs [daemon|vpn]
              uoa-proxy help

            Control socket:
              \(AppPaths.socketURL.path)
            """
        )
    }
}
