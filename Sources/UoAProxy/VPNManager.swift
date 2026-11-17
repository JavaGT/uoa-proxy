import AppKit
import Combine
import Foundation
import UoAProxyCore

@MainActor
final class VPNManager: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published var statusMessage: String = "Ready"
    @Published var lastError: String?
    @Published var config: VPNConfig = .defaults
    @Published var password: String = ""
    @Published var totpSecret: String = ""
    @Published var currentOTP: String = "------"
    @Published var otpSecondsRemaining: Int = 30
    @Published var hasPassword: Bool = false
    @Published var hasTOTPSecret: Bool = false
    @Published var daemonConnected: Bool = false
    @Published var sudoOK: Bool = false
    @Published var needsSetup: Bool = false
    @Published var showSetupSheet: Bool = false
    @Published private(set) var operation: VPNOperation = .idle
    var installingHelper: Bool { operation == .installingHelper }

    private var otpTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var lastOTPFetchRemaining: Int = -1

    /// Bumped when a user action starts so stale poll results are dropped.
    private var actionGeneration: UInt64 = 0
    private var pollInFlight = false

    init() {
        config = VPNConfig.load()
        loadLocalSecretFields()
        startTimers()
        Task { await refreshFromDaemonAsync() }
    }

    deinit {
        otpTimer?.invalidate()
        pollTask?.cancel()
    }

    private func startTimers() {
        otpTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let manager = self
            Task { @MainActor in
                manager?.tickOTPLocal()
            }
        }
        // Single serial poll loop — never overlaps status calls.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refreshFromDaemonAsync()
            }
        }
    }

    func loadLocalSecretFields() {
        password = ""
        totpSecret = ""
    }

    func refreshFromDaemon() {
        Task { await refreshFromDaemonAsync() }
    }

    private func refreshFromDaemonAsync() async {
        // Allow status during connect so the UI can track progress; skip only
        // when a poll is already running.
        guard !pollInFlight, !installingHelper, operation != .saving else { return }
        pollInFlight = true
        let genAtStart = actionGeneration
        defer { pollInFlight = false }

        let result = await Self.ipc { try DaemonClient(autoStart: true).status() }
        // Drop stale results if a user action started after we began.
        guard genAtStart == actionGeneration else { return }

        switch result {
        case .success(let r):
            // Don't clobber local transitional UI mid disconnect/connect with
            // an older snapshot that still says connected/connecting incorrectly
            // — but daemon is source of truth once settled.
            apply(r, clearErrorsOnSettled: true)
            daemonConnected = true
        case .failure(let error):
            daemonConnected = false
            lastError = error.localizedDescription
            statusMessage = "Daemon offline"
            needsSetup = true
        }
    }

    private func tickOTPLocal() {
        let remaining = TOTPGenerator.secondsRemaining()
        otpSecondsRemaining = remaining
        guard daemonConnected, hasTOTPSecret else { return }

        let shouldFetch =
            currentOTP == "------"
            || remaining > lastOTPFetchRemaining
            || lastOTPFetchRemaining < 0

        guard shouldFetch else { return }
        // Optimistically mark so we don't stampede; on failure reset.
        lastOTPFetchRemaining = remaining

        Task {
            let result = await Self.ipc { try DaemonClient(autoStart: false).otp() }
            switch result {
            case .success(let r):
                if let otp = r.otp { currentOTP = otp }
                if let sec = r.otpSecondsRemaining {
                    otpSecondsRemaining = sec
                    lastOTPFetchRemaining = sec
                }
            case .failure:
                // Allow retry on next tick.
                lastOTPFetchRemaining = -1
            }
        }
    }

    private func apply(_ r: IPCResponse, clearErrorsOnSettled: Bool = false) {
        if !(operation == .connecting && r.state == .disconnected)
            && !(operation == .disconnecting && (r.state == .connected || r.state == .connecting)) {
            state = r.state
        }
        statusMessage = r.message
        if let err = r.error, !err.isEmpty {
            lastError = err
        } else if clearErrorsOnSettled, r.state == .connected || r.state == .disconnected {
            lastError = nil
        }
        if r.state == .connected {
            lastError = nil
        }
        if let u = r.username { config.username = u }
        if let s = r.server { config.server = s }
        if let p = r.openconnectPath { config.openconnectPath = p }
        if let pr = r.protocolName { config.protocolName = pr }
        hasPassword = r.hasPassword ?? false
        hasTOTPSecret = r.hasTOTPSecret ?? false
        if let otp = r.otp { currentOTP = otp }
        if let sec = r.otpSecondsRemaining {
            otpSecondsRemaining = sec
            lastOTPFetchRemaining = sec
        }
        sudoOK = r.sudoOK ?? false
        let needs = SetupNeeds.from(response: r)
        needsSetup = needs.username || needs.password || needs.totp || needs.openconnect || needs.sudo
    }

    var credentialSetupIncomplete: Bool {
        config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !hasPassword
            || !hasTOTPSecret
    }

    /// Whether the Connect/Disconnect control should be enabled.
    var canAct: Bool {
        daemonConnected && (operation == .idle || operation == .connecting)
    }

    /// Primary button label.
    var actionTitle: String {
        switch state {
        case .disconnected: return "Connect"
        case .connecting: return "Cancel"
        case .connected: return "Disconnect"
        case .disconnecting: return "Disconnecting…"
        }
    }

    func saveSettings() async -> Bool {
        guard operation.canBegin(.saving) else { return false }
        operation = .saving
        actionGeneration &+= 1
        statusMessage = "Saving…"
        defer { operation = .idle }
            let cfg = config
            let pass = password
            let totp = totpSecret
            let result = await Self.ipc { () throws -> IPCResponse in
                let client = DaemonClient(autoStart: true)
                let r1 = try client.setConfig(cfg)
                guard r1.ok else {
                    throw IPCError.commandFailed(r1.error ?? "setConfig failed")
                }
                if !pass.isEmpty {
                    let r2 = try client.setPassword(pass)
                    guard r2.ok else {
                        throw IPCError.commandFailed(r2.error ?? "setPassword failed")
                    }
                }
                if !totp.isEmpty {
                    let r3 = try client.setTOTPSecret(totp)
                    guard r3.ok else {
                        throw IPCError.commandFailed(r3.error ?? "setTOTPSecret failed")
                    }
                }
                return try client.status()
            }
            switch result {
            case .success(let r):
                password = ""
                totpSecret = ""
                apply(r, clearErrorsOnSettled: true)
                statusMessage = "Settings saved"
                lastError = nil
                daemonConnected = true
                return true
            case .failure(let error):
                lastError = error.localizedDescription
                statusMessage = "Save failed"
                return false
            }
    }

    func connect() {
        guard operation.canBegin(.connecting) else { return }
        if credentialSetupIncomplete || !sudoOK {
            showSetupSheet = true
            if credentialSetupIncomplete {
                lastError = "Finish setup to connect (username, password, TOTP)."
            } else if !sudoOK {
                lastError = "Install the VPN helper in setup to connect."
            }
            if credentialSetupIncomplete || !sudoOK {
                return
            }
        }

        // Don't start another connect while disconnecting or already connecting.
        guard state == .disconnected else { return }

        actionGeneration &+= 1
        let gen = actionGeneration
        operation = .connecting
        state = .connecting
        statusMessage = "Connecting…"
        lastError = nil
        Task {
            defer {
                if gen == actionGeneration {
                    operation = .idle
                }
            }
            let result = await Self.ipc { try DaemonClient(autoStart: true).connect() }
            guard gen == actionGeneration else { return }
            operation = .idle
            switch result {
            case .success(let r):
                apply(r)
                daemonConnected = true
                if r.state != .connected {
                    let needs = SetupNeeds.from(response: r)
                    if !needs.isReady {
                        showSetupSheet = true
                    }
                }
            case .failure(let error):
                lastError = error.localizedDescription
                statusMessage = "Failed"
                state = .disconnected
            }
        }
    }

    /// Cancel an in-flight connect or drop an active tunnel.
    /// A disconnect supersedes an in-flight connect.
    func disconnect() {
        guard operation.canBegin(.disconnecting) else { return }

        actionGeneration &+= 1
        let gen = actionGeneration
        // Supersede any outstanding connect result.
        operation = .disconnecting
        state = .disconnecting
        statusMessage = "Disconnecting…"
        lastError = nil
        Task {
            defer {
                if gen == actionGeneration {
                    operation = .idle
                }
            }
            let result = await Self.ipc { try DaemonClient(autoStart: true).disconnect() }
            guard gen == actionGeneration else { return }
            operation = .idle
            switch result {
            case .success(let r):
                apply(r)
                daemonConnected = true
                if r.state == .disconnected {
                    lastError = r.error
                    statusMessage = "Disconnected"
                }
            case .failure(let error):
                lastError = error.localizedDescription
                // Let any stale poll finish before starting a fresh one.
                while pollInFlight { try? await Task.sleep(nanoseconds: 100_000_000) }
                await refreshFromDaemonAsync()
            }
        }
    }

    func toggle() {
        switch state {
        case .connected, .connecting:
            disconnect()
        case .disconnected:
            connect()
        case .disconnecting:
            break
        }
    }

    func installHelper() async -> String? {
        guard operation.canBegin(.installingHelper) else { return "Wait for the current operation to finish, then try again." }
        guard state == .disconnected else { return "Disconnect before installing the VPN helper." }
        operation = .installingHelper
        actionGeneration &+= 1
        while pollInFlight { try? await Task.sleep(nanoseconds: 100_000_000) }
        let result = await Self.ipc { try NativeHelperInstaller.install() }
        operation = .idle
        await refreshFromDaemonAsync()
        switch result {
        case .success:
            return sudoOK ? nil : "The helper was installed, but could not be verified. Try again."
        case .failure(let error):
            return error.localizedDescription
        }
    }

    // MARK: - Background IPC

    private static func ipc<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: .success(try work()))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }
}
