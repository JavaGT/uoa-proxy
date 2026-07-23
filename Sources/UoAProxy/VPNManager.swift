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

    private var otpTimer: Timer?
    private var pollTask: Task<Void, Never>?
    private var didAutoPresentSetup = false
    private var lastOTPFetchRemaining: Int = -1

    /// Bumped on every user connect/disconnect so stale poll results are dropped.
    private var actionGeneration: UInt64 = 0
    /// True while a user-driven connect IPC is outstanding.
    private var connectInFlight = false
    /// True while a user-driven disconnect IPC is outstanding.
    private var disconnectInFlight = false
    private var saveInFlight = false
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
        guard !pollInFlight else { return }
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
            if needsSetup && !didAutoPresentSetup && state == .disconnected {
                didAutoPresentSetup = true
                showSetupSheet = true
            }
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
        state = r.state
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
        daemonConnected && !disconnectInFlight && !saveInFlight
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

    func saveSettings() {
        guard !saveInFlight else { return }
        saveInFlight = true
        statusMessage = "Saving…"
        Task {
            defer { saveInFlight = false }
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
            case .failure(let error):
                lastError = error.localizedDescription
            }
        }
    }

    func connect() {
        if credentialSetupIncomplete || !sudoOK {
            showSetupSheet = true
            if credentialSetupIncomplete {
                lastError = "Finish setup to connect (username, password, TOTP)."
            } else if !sudoOK {
                lastError = "Passwordless sudo is required. Run: uoa-proxy install-sudo"
            }
            if credentialSetupIncomplete || !sudoOK {
                return
            }
        }

        // Don't start another connect while disconnecting or already connecting.
        guard !connectInFlight, !disconnectInFlight else { return }
        guard state == .disconnected else { return }

        actionGeneration &+= 1
        let gen = actionGeneration
        connectInFlight = true
        state = .connecting
        statusMessage = "Connecting…"
        lastError = nil
        Task {
            defer {
                if gen == actionGeneration {
                    connectInFlight = false
                }
            }
            let result = await Self.ipc { try DaemonClient(autoStart: true).connect() }
            guard gen == actionGeneration else { return }
            connectInFlight = false
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
    /// Always allowed while connecting — must not be blocked by connectInFlight.
    func disconnect() {
        guard !disconnectInFlight else { return }

        actionGeneration &+= 1
        let gen = actionGeneration
        // Supersede any outstanding connect result.
        connectInFlight = false
        disconnectInFlight = true
        state = .disconnecting
        statusMessage = "Disconnecting…"
        lastError = nil
        Task {
            defer {
                if gen == actionGeneration {
                    disconnectInFlight = false
                }
            }
            let result = await Self.ipc { try DaemonClient(autoStart: true).disconnect() }
            guard gen == actionGeneration else { return }
            disconnectInFlight = false
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
                // Force refresh even if another poll is running.
                pollInFlight = false
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

    func installPasswordlessSudo() {
        lastError = "Run in Terminal (works over SSH):\n  uoa-proxy install-sudo"
        statusMessage = "See note for install-sudo"
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
