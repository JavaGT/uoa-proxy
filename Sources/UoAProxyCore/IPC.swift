import Foundation

/// Connection lifecycle as reported by the daemon.
public enum ConnectionState: String, Codable, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        }
    }
}

/// Client → daemon request (one JSON object per line).
public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var cmd: Command

    public var username: String?
    public var server: String?
    public var openconnectPath: String?
    public var protocolName: String?
    public var password: String?
    public var totpSecret: String?

    public enum Command: String, Codable, Sendable {
        case ping
        case status
        case connect
        case disconnect
        case toggle
        case shutdown
        case otp
        case getConfig = "get_config"
        case setConfig = "set_config"
        case setPassword = "set_password"
        case setTOTPSecret = "set_totp_secret"
        case clearPassword = "clear_password"
        case clearTOTPSecret = "clear_totp_secret"
    }

    public init(id: String = UUID().uuidString, cmd: Command) {
        self.id = id
        self.cmd = cmd
    }
}

/// Daemon → client response.
public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var state: ConnectionState
    public var message: String
    public var error: String?

    public var username: String?
    public var server: String?
    public var openconnectPath: String?
    public var protocolName: String?
    public var hasPassword: Bool?
    public var hasTOTPSecret: Bool?
    public var otp: String?
    public var otpSecondsRemaining: Int?
    public var sudoOK: Bool?
    public var daemonPID: Int32?

    public init(
        id: String,
        ok: Bool,
        state: ConnectionState,
        message: String,
        error: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.state = state
        self.message = message
        self.error = error
    }
}

public enum IPCError: LocalizedError {
    case daemonUnavailable(String)
    case protocolError(String)
    case commandFailed(String)
    /// Request may have been delivered; must not be transparently retried.
    case outcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .daemonUnavailable(let detail):
            return "Daemon unavailable: \(detail)"
        case .protocolError(let detail):
            return "IPC protocol error: \(detail)"
        case .commandFailed(let detail):
            return detail
        case .outcomeUnknown(let detail):
            return "Outcome unknown (do not retry blindly): \(detail)"
        }
    }
}

public extension IPCRequest.Command {
    /// Default socket I/O deadline for this command.
    var defaultTimeout: TimeInterval {
        switch self {
        case .connect, .disconnect, .toggle, .shutdown:
            return 90
        case .setConfig, .setPassword, .setTOTPSecret, .clearPassword, .clearTOTPSecret:
            return 10
        case .ping, .status, .otp, .getConfig:
            return 3
        }
    }

    /// Whether replaying this command after an ambiguous failure is unsafe.
    var isMutating: Bool {
        switch self {
        case .connect, .disconnect, .toggle, .shutdown,
             .setConfig, .setPassword, .setTOTPSecret,
             .clearPassword, .clearTOTPSecret:
            return true
        case .ping, .status, .otp, .getConfig:
            return false
        }
    }
}
