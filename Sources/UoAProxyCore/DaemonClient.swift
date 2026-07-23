import Darwin
import Foundation

/// Talks to `uoa-proxyd` over the control socket.
public struct DaemonClient: Sendable {
    public var socketPath: String
    public var autoStart: Bool

    public init(
        socketPath: String = AppPaths.socketURL.path,
        autoStart: Bool = true
    ) {
        self.socketPath = socketPath
        self.autoStart = autoStart
    }

    public func ping() throws -> IPCResponse {
        try send(IPCRequest(cmd: .ping))
    }

    public func status() throws -> IPCResponse {
        try send(IPCRequest(cmd: .status))
    }

    public func connect() throws -> IPCResponse {
        try send(IPCRequest(cmd: .connect))
    }

    public func disconnect() throws -> IPCResponse {
        try send(IPCRequest(cmd: .disconnect))
    }

    public func toggle() throws -> IPCResponse {
        try send(IPCRequest(cmd: .toggle))
    }

    public func shutdown() throws -> IPCResponse {
        try send(IPCRequest(cmd: .shutdown))
    }

    public func otp() throws -> IPCResponse {
        try send(IPCRequest(cmd: .otp))
    }

    public func getConfig() throws -> IPCResponse {
        try send(IPCRequest(cmd: .getConfig))
    }

    public func setConfig(_ config: VPNConfig) throws -> IPCResponse {
        var req = IPCRequest(cmd: .setConfig)
        req.username = config.username
        req.server = config.server
        req.openconnectPath = config.openconnectPath
        req.protocolName = config.protocolName
        return try send(req)
    }

    public func setPassword(_ password: String) throws -> IPCResponse {
        var req = IPCRequest(cmd: .setPassword)
        req.password = password
        return try send(req)
    }

    public func setTOTPSecret(_ secret: String) throws -> IPCResponse {
        var req = IPCRequest(cmd: .setTOTPSecret)
        req.totpSecret = secret
        return try send(req)
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        do {
            return try sendOnce(request)
        } catch let error as IPCError {
            // Only auto-start + retry when we never reached the daemon at all.
            // Never retry after a write began (mutations must be at-most-once).
            if autoStart, case .daemonUnavailable = error {
                try DaemonLifecycle.ensureRunning()
                for _ in 0..<30 {
                    if DaemonLifecycle.isDaemonResponsive() { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return try sendOnce(request)
            }
            throw error
        } catch {
            throw error
        }
    }

    private func sendOnce(_ request: IPCRequest) throws -> IPCResponse {
        let timeout = request.cmd.defaultTimeout
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketPath, timeout: min(timeout, 5))
        } catch {
            throw IPCError.daemonUnavailable(
                "cannot connect to \(socketPath) (\(error.localizedDescription)). Is uoa-proxyd running? Try: uoa-proxy daemon start"
            )
        }
        defer { UnixSocket.close(fd) }

        // Long-running connect/disconnect need a longer I/O deadline than connect(2).
        UnixSocket.setIOTimeouts(fd, seconds: timeout)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data: Data
        do {
            data = try encoder.encode(request)
        } catch {
            throw IPCError.protocolError("encode failed: \(error.localizedDescription)")
        }
        guard let line = String(data: data, encoding: .utf8) else {
            throw IPCError.protocolError("encode produced non-UTF8")
        }

        // From the first write attempt onward, failures for mutating commands
        // are outcome-unknown (must not auto-retry).
        var didWrite = false
        do {
            try UnixSocket.writeLine(fd, line)
            didWrite = true
            let responseLine = try UnixSocket.readLine(fd)
            guard let responseData = responseLine.data(using: .utf8) else {
                throw IPCError.protocolError("empty response")
            }
            let response = try decoder.decode(IPCResponse.self, from: responseData)
            if response.id != request.id {
                throw IPCError.protocolError(
                    "response id mismatch (want \(request.id), got \(response.id))"
                )
            }
            return response
        } catch let error as IPCError {
            throw error
        } catch {
            if didWrite && request.cmd.isMutating {
                throw IPCError.outcomeUnknown(
                    "\(request.cmd.rawValue) id=\(request.id): \(error.localizedDescription). Check: uoa-proxy status"
                )
            }
            throw IPCError.protocolError(error.localizedDescription)
        }
    }
}

/// Start/stop the LaunchAgent or a foreground daemon process.
public enum DaemonLifecycle {
    /// True if a responsive daemon answers ping (not merely that a socket file exists).
    public static func isDaemonResponsive() -> Bool {
        do {
            let r = try DaemonClient(autoStart: false).ping()
            return r.ok
        } catch {
            return false
        }
    }

    /// Backward-compatible name used by CLI status.
    public static func isSocketLive() -> Bool {
        isDaemonResponsive()
    }

    public static func ensureRunning() throws {
        if isDaemonResponsive() { return }

        // Prefer LaunchAgent only when an Aqua GUI domain is available.
        // Over SSH, launchctl gui/ often fails — use --daemonize instead.
        if launchAgentInstalled(), isAquaSession() {
            do {
                try bootstrapLaunchAgent()
                if isDaemonResponsive() { return }
            } catch {
                // fall through
            }
        }

        // If something holds the lock but is not answering, do not start another
        // unmanaged instance that would fight it.
        if DaemonOwnership.isHeldByAnyone(), !isDaemonResponsive() {
            // Brief grace for a starting daemon.
            for _ in 0..<20 {
                if isDaemonResponsive() { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw IPCError.daemonUnavailable(
                "uoa-proxyd lock is held but the control socket is not responding. Try: uoa-proxy daemon restart"
            )
        }

        try startDaemonized()
        for _ in 0..<50 {
            if isDaemonResponsive() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw IPCError.daemonUnavailable(
            "uoa-proxyd did not open \(AppPaths.socketURL.path). Check \(AppPaths.daemonLogURL.path)"
        )
    }

    public static func startDaemonized() throws {
        guard let binary = AppPaths.resolveDaemonBinary() else {
            throw IPCError.daemonUnavailable(
                "uoa-proxyd not found. Run ./Scripts/install.sh first."
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--daemonize"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw IPCError.daemonUnavailable("failed to start uoa-proxyd (exit \(process.terminationStatus))")
        }
    }

    public static func launchAgentPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(AppPaths.launchAgentLabel).plist")
    }

    public static func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL().path)
    }

    public static func isAquaSession() -> Bool {
        let r = runCapture("/bin/launchctl", arguments: ["managername"])
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "Aqua"
    }

    public static func bootstrapLaunchAgent() throws {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let label = AppPaths.launchAgentLabel
        let plist = launchAgentPlistURL().path

        // Prefer gentle kickstart (no -k kill) when already loaded.
        _ = runCapture("/bin/launchctl", arguments: ["kickstart", "\(domain)/\(label)"])
        if isDaemonResponsive() { return }

        let boot = runCapture("/bin/launchctl", arguments: ["bootstrap", domain, plist])
        if boot.status != 0 {
            _ = runCapture("/bin/launchctl", arguments: ["enable", "\(domain)/\(label)"])
            _ = runCapture("/bin/launchctl", arguments: ["kickstart", "\(domain)/\(label)"])
        }

        for _ in 0..<30 {
            if isDaemonResponsive() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw IPCError.daemonUnavailable(
            "LaunchAgent did not open the control socket (often expected over SSH)."
        )
    }

    public static func bootoutLaunchAgent() {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let label = AppPaths.launchAgentLabel
        _ = runCapture("/bin/launchctl", arguments: ["bootout", "\(domain)/\(label)"])
    }

    /// Ask the exact responsive daemon to shut down its owned VPN and exit.
    public static func stopDaemon() throws {
        if isDaemonResponsive() {
            do {
                _ = try DaemonClient(autoStart: false).shutdown()
            } catch {
                // A lost shutdown response is acceptable if the daemon exits.
                if isDaemonResponsive() { throw error }
            }
        }
        for _ in 0..<50 {
            if !isDaemonResponsive() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if isDaemonResponsive() {
            throw IPCError.commandFailed("daemon refused a graceful shutdown; no PID or name-based kill was attempted")
        }
        bootoutLaunchAgent()
        UnixSocket.removeSocketFile(at: AppPaths.socketURL.path)
    }

    @discardableResult
    private static func runCapture(_ path: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do {
            try process.run()
            process.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, text)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
