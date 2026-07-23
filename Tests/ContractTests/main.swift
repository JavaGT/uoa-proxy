import Foundation
import UoAProxyCore

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("contract test failed: \(message)\n", stderr)
        exit(1)
    }
}

for command in [
    IPCRequest.Command.connect,
    .disconnect,
    .toggle,
    .shutdown
] {
    expect(command.isMutating, "\(command.rawValue) must be at-most-once")
    expect(command.defaultTimeout == 90, "\(command.rawValue) must have bounded lifecycle timeout")
}

for command in [
    IPCRequest.Command.ping,
    .status,
    .otp,
    .getConfig
] {
    expect(!command.isMutating, "\(command.rawValue) must remain retry-safe")
    expect(command.defaultTimeout == 3, "\(command.rawValue) must have short timeout")
}

print("IPC contract tests passed")
