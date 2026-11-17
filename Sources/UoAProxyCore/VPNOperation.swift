import Foundation

/// Mutually exclusive user actions. A disconnect may supersede a connect.
public enum VPNOperation: Equatable, Sendable {
    case idle, connecting, disconnecting, saving, installingHelper

    public func canBegin(_ next: VPNOperation) -> Bool {
        switch (self, next) {
        case (.idle, .connecting), (.idle, .disconnecting), (.idle, .saving),
             (.idle, .installingHelper), (.connecting, .disconnecting):
            return true
        default:
            return false
        }
    }
}
