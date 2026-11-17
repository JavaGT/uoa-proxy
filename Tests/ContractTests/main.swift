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

expect(VPNOperation.idle.canBegin(.connecting), "idle must allow connect")
expect(VPNOperation.connecting.canBegin(.disconnecting), "connect must allow cancel")
for operation in [VPNOperation.connecting, .disconnecting, .saving, .installingHelper] {
    expect(!operation.canBegin(.installingHelper), "busy operation must block helper installation")
    expect(!operation.canBegin(.saving), "busy operation must block settings save")
}
expect(!VPNOperation.disconnecting.canBegin(.connecting), "disconnect must block connect")
print("VPN operation transition tests passed")

// Staged privileged artefacts must never be group/other writable: both the
// installer's integrity check and the root helper reject such files.
expect(StagedInstallPermissions.isSafe(mode_t(S_IFREG | 0o755)), "755 must be a safe staged file")
expect(StagedInstallPermissions.isSafe(mode_t(S_IFREG | 0o444)), "444 must be a safe staged file")
expect(!StagedInstallPermissions.isSafe(mode_t(S_IFREG | 0o775)), "group-writable staged file must be rejected")
expect(!StagedInstallPermissions.isSafe(mode_t(S_IFREG | 0o757)), "other-writable staged file must be rejected")
expect(!StagedInstallPermissions.isSafe(mode_t(S_IFDIR | 0o755)), "directories must not pass the file check")
expect(!StagedInstallPermissions.isSafe(mode_t(S_IFLNK | 0o755)), "symlinks must not pass the file check")
print("Staged install permission tests passed")
