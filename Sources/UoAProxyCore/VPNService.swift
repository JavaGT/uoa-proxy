import Darwin
import Foundation

/// Owns exactly one foreground openconnect process group. Used by the daemon.
public actor VPNService {
    public private(set) var state: ConnectionState = .disconnected
    public private(set) var message: String = "Ready"
    public private(set) var lastError: String?

    private var ownedProcess: OwnedVPNProcess?
    private var sessionGeneration: UInt64 = 0
    private var connectInFlight = false
    private var desiredConnected = false
    private var currentAttemptIsReconnect = false
    private var reconnectTask: Task<Void, Never>?

    private var cachedSudoOK: Bool?
    private var cachedSudoOKAt: Date = .distantPast
    private let sudoOKCacheTTL: TimeInterval = 60

    public init() {}

    public func snapshot() -> ServiceSnapshot {
        let config = VPNConfig.load()
        let password = (try? KeychainStore.load(account: .password)) ?? ""
        let totp = (try? KeychainStore.load(account: .totpSecret)) ?? ""
        let cleaned = TOTPGenerator.normalizeSecret(totp)
        let otp = cleaned.isEmpty ? nil : try? TOTPGenerator.generate(secretBase32: cleaned)

        if state == .connected, !isOwnedProcessRunning() {
            state = .disconnected
            message = desiredConnected ? "Reconnecting…" : "Disconnected"
        }

        return ServiceSnapshot(
            state: state,
            message: message,
            error: lastError,
            config: config,
            hasPassword: !password.isEmpty,
            hasTOTPSecret: !cleaned.isEmpty,
            otp: otp,
            otpSecondsRemaining: TOTPGenerator.secondsRemaining(),
            sudoOK: sudoOKCached(),
            daemonPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    public func connect() async {
        desiredConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        await attemptConnection(isReconnect: false)
    }

    public func disconnect() async {
        desiredConnected = false
        sessionGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil

        guard let process = ownedProcess, process.isRunning else {
            ownedProcess = nil
            connectInFlight = false
            state = .disconnected
            message = "Disconnected"
            lastError = nil
            return
        }

        state = .disconnecting
        message = "Disconnecting…"
        lastError = nil
        process.signalGroup(SIGTERM)
        if !(await waitForExit(process, seconds: 5)) {
            process.signalGroup(SIGKILL)
            _ = await waitForExit(process, seconds: 2)
        }

        if process.isRunning {
            state = .disconnecting
            message = "Disconnect failed"
            lastError = "The owned VPN process group did not exit. The daemon will not adopt or signal any other process."
        } else {
            if ownedProcess?.id == process.id { ownedProcess = nil }
            connectInFlight = false
            state = .disconnected
            message = "Disconnected"
        }
    }

    public func toggle() async {
        if desiredConnected || state == .connected || state == .connecting {
            await disconnect()
        } else {
            await connect()
        }
    }

    public func shutdown() async {
        desiredConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let process = ownedProcess, process.isRunning {
            process.signalGroup(SIGTERM)
            if !(await waitForExit(process, seconds: 5)) {
                process.signalGroup(SIGKILL)
                _ = await waitForExit(process, seconds: 2)
            }
        }
    }

    // MARK: - Config helpers

    public func setConfig(_ config: VPNConfig) {
        config.save()
        message = "Config saved"
        lastError = nil
    }

    public func setPassword(_ password: String) throws {
        if password.isEmpty {
            try KeychainStore.delete(account: .password)
        } else {
            try KeychainStore.save(password, account: .password)
        }
        message = "Password saved"
        lastError = nil
    }

    public func setTOTPSecret(_ secret: String) throws {
        let cleaned = TOTPGenerator.normalizeSecret(secret)
        if cleaned.isEmpty {
            try KeychainStore.delete(account: .totpSecret)
        } else {
            _ = try TOTPGenerator.generate(secretBase32: cleaned)
            try KeychainStore.save(cleaned, account: .totpSecret)
        }
        message = "TOTP secret saved"
        lastError = nil
    }

    // MARK: - Connection lifecycle

    private func attemptConnection(isReconnect: Bool) async {
        if isOwnedProcessRunning() {
            state = .connected
            message = "Connected"
            lastError = nil
            return
        }
        if connectInFlight {
            let generation = sessionGeneration
            while connectInFlight, generation == sessionGeneration {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }

        guard let inputs = validatedInputs() else {
            desiredConnected = false
            return
        }
        invalidateSudoOKCache()
        guard sudoOKCached(force: true) else {
            fail("The fixed privileged VPN runner is not installed. Run: uoa-proxy install-sudo")
            desiredConnected = false
            return
        }
        guard let supervisor = AppPaths.resolveSupervisorBinary() else {
            fail("uoa-proxy-supervisor is missing. Run ./Scripts/install.sh again.")
            desiredConnected = false
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        connectInFlight = true
        currentAttemptIsReconnect = isReconnect
        state = .connecting
        message = isReconnect ? "Reconnecting…" : "Connecting…"
        lastError = nil
        defer { connectInFlight = false }

        do {
            if TOTPGenerator.secondsRemaining() <= 2 {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            }
            guard desiredConnected, generation == sessionGeneration else { return }
            let otp = try TOTPGenerator.generate(secretBase32: inputs.secret)
            let id = UUID()
            let process = OwnedVPNProcess(
                id: id,
                executable: supervisor,
                arguments: ["connect", "--user", inputs.username, "--server", inputs.server],
                standardInput: "\(inputs.password)\n\(otp)\n",
                redactions: [inputs.password, otp]
            ) { [weak self] id, status, output in
                let service = self
                Task {
                    await service?.ownedProcessExited(id: id, status: status, output: output)
                }
            }
            try process.start()
            ownedProcess = process

            // Foreground openconnect remains alive after authentication. Prefer
            // its explicit success messages, with a stable-process fallback for
            // Fortinet builds whose wording differs.
            let started = Date()
            while Date().timeIntervalSince(started) < 12 {
                guard desiredConnected, generation == sessionGeneration else {
                    process.signalGroup(SIGTERM)
                    return
                }
                guard process.isRunning else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    return
                }
                if outputShowsConnected(process.output) || Date().timeIntervalSince(started) >= 5 {
                    state = .connected
                    message = "Connected"
                    lastError = nil
                    currentAttemptIsReconnect = false
                    return
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            if generation == sessionGeneration {
                fail(error.localizedDescription)
                if !isReconnect { desiredConnected = false }
            }
        }
    }

    private func ownedProcessExited(id: UUID, status: Int32, output: String) {
        guard ownedProcess?.id == id else { return }
        ownedProcess = nil
        connectInFlight = false
        writeVPNLog(output)

        let wasConnected = state == .connected
        let wasReconnect = currentAttemptIsReconnect
        currentAttemptIsReconnect = false
        state = .disconnected

        if !desiredConnected {
            message = "Disconnected"
            return
        }

        let detail = usefulFailure(output, status: status)
        lastError = detail
        if !wasConnected, !wasReconnect || isAuthenticationFailure(output) {
            desiredConnected = false
            message = "Failed"
            return
        }

        message = "Reconnecting…"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard desiredConnected, reconnectTask == nil else { return }
        let generation = sessionGeneration
        reconnectTask = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      await self.reconnectIsAllowed(generation: generation) else { break }
                await self.attemptConnection(isReconnect: true)
                if await self.isOwnedProcessRunning() { break }
                delay = min(delay * 2, 30)
            }
            await self?.reconnectLoopFinished()
        }
    }

    private func reconnectIsAllowed(generation: UInt64) -> Bool {
        desiredConnected && generation <= sessionGeneration && !isOwnedProcessRunning()
    }

    private func reconnectLoopFinished() {
        reconnectTask = nil
    }

    private func waitForExit(_ process: OwnedVPNProcess, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !process.isRunning
    }

    private func isOwnedProcessRunning() -> Bool {
        ownedProcess?.isRunning == true
    }

    // MARK: - Validation and diagnostics

    private struct Inputs {
        let username: String
        let server: String
        let password: String
        let secret: String
    }

    private func validatedInputs() -> Inputs? {
        let config = VPNConfig.load()
        let username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = config.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (try? KeychainStore.load(account: .password)) ?? ""
        let secret = TOTPGenerator.normalizeSecret((try? KeychainStore.load(account: .totpSecret)) ?? "")
        guard !username.isEmpty else { fail("Username is not configured. Run: uoa-proxy config set user <upi>"); return nil }
        guard !password.isEmpty else { fail("Password is not configured. Run: uoa-proxy config set password"); return nil }
        guard !secret.isEmpty else { fail("TOTP secret is not configured. Run: uoa-proxy config set totp"); return nil }
        guard ["connectvpn.auckland.ac.nz/client", "https://connectvpn.auckland.ac.nz/client"].contains(server) else {
            fail("For safety, the privileged runner only connects to connectvpn.auckland.ac.nz/client.")
            return nil
        }
        return Inputs(username: username, server: server, password: password, secret: secret)
    }

    private func outputShowsConnected(_ output: String) -> Bool {
        let lower = output.lowercased()
        return ["connected as ", "session established", "tunnel is up", "configured as "].contains {
            lower.contains($0)
        }
    }

    private func isAuthenticationFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return ["authentication failed", "login failed", "invalid password", "http response 401", "failed to obtain webvpn cookie"].contains {
            lower.contains($0)
        }
    }

    private func usefulFailure(_ output: String, status: Int32) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(12).joined(separator: "\n")
        return lines.isEmpty ? "openconnect exited with status \(status)" : lines
    }

    private func writeVPNLog(_ output: String) {
        guard !output.isEmpty else { return }
        let bounded = String(output.suffix(256 * 1024))
        try? bounded.write(to: AppPaths.openconnectLogURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.openconnectLogURL.path)
    }

    private func fail(_ error: String) {
        state = .disconnected
        message = "Failed"
        lastError = error
    }

    private func sudoOKCached(force: Bool = false) -> Bool {
        let now = Date()
        if !force, let cachedSudoOK, now.timeIntervalSince(cachedSudoOKAt) < sudoOKCacheTTL {
            return cachedSudoOK
        }
        let ok = SudoersInstaller.isPasswordlessSudoAvailable(timeout: 5)
        cachedSudoOK = ok
        cachedSudoOKAt = now
        return ok
    }

    private func invalidateSudoOKCache() {
        cachedSudoOK = nil
        cachedSudoOKAt = .distantPast
    }
}

private final class OwnedVPNProcess: @unchecked Sendable {
    let id: UUID
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let capture = LockedData(limit: 1_048_576)
    private let standardInput: String
    private let redactions: [String]
    private let onExit: @Sendable (UUID, Int32, String) -> Void

    init(
        id: UUID,
        executable: String,
        arguments: [String],
        standardInput: String,
        redactions: [String],
        onExit: @escaping @Sendable (UUID, Int32, String) -> Void
    ) {
        self.id = id
        self.standardInput = standardInput
        self.redactions = redactions.filter { !$0.isEmpty }
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    var isRunning: Bool { process.isRunning }
    var output: String { sanitize(capture.string) }

    func start() throws {
        stdout.fileHandleForReading.readabilityHandler = { [capture] handle in
            capture.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { [capture] handle in
            capture.append(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.stdout.fileHandleForReading.readabilityHandler = nil
            self.stderr.fileHandleForReading.readabilityHandler = nil
            self.capture.append(self.stdout.fileHandleForReading.readDataToEndOfFile())
            self.capture.append(self.stderr.fileHandleForReading.readDataToEndOfFile())
            self.onExit(self.id, process.terminationStatus, self.output)
        }
        try process.run()
        stdin.fileHandleForWriting.write(Data(standardInput.utf8))
        try? stdin.fileHandleForWriting.close()
    }

    func signalGroup(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // The supervisor calls setsid before execing sudo. If disconnect wins
        // that startup race, signal the still-exact supervisor PID instead.
        if kill(-pid, signal) != 0, errno == ESRCH {
            _ = kill(pid, signal)
        }
    }

    private func sanitize(_ value: String) -> String {
        redactions.reduce(value) { result, secret in
            result.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: storage, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        storage.append(chunk)
        if storage.count > limit { storage = storage.suffix(limit) }
    }
}

public struct ServiceSnapshot: Sendable {
    public var state: ConnectionState
    public var message: String
    public var error: String?
    public var config: VPNConfig
    public var hasPassword: Bool
    public var hasTOTPSecret: Bool
    public var otp: String?
    public var otpSecondsRemaining: Int
    public var sudoOK: Bool
    public var daemonPID: Int32
}

public enum VPNError: LocalizedError {
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let message): return message
        }
    }
}
