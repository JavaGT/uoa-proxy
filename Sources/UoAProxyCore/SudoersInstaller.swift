import Darwin
import Foundation

/// Installs the fixed privileged runner and a single-command sudoers rule.
public enum SudoersInstaller {
    public static func install(openconnectPath _: String = VPNConfig.load().openconnectPath) throws {
        let user = NSUserName()
        guard !user.isEmpty,
              user.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
              }) else {
            throw VPNError.connectFailed("Cannot safely install sudoers for this account name.")
        }
        guard let helperSource = AppPaths.resolveHelperSource() else {
            throw VPNError.connectFailed("uoa-proxy-helper is not installed. Run ./Scripts/install.sh first.")
        }
        guard let runtimeSource = AppPaths.resolveOpenconnectRuntimeSource() else {
            throw VPNError.connectFailed("Bundled openconnect runtime is missing. Run ./Scripts/build.sh and ./Scripts/install.sh.")
        }

        let contents = """
        # UoA Proxy - fixed, validating privileged VPN runner only
        # Managed by uoa-proxy
        \(user) ALL=(root) NOPASSWD: \(AppPaths.privilegedHelperPath)

        """
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("uoa-proxy-sudoers-\(UUID().uuidString)")
        try contents.write(to: temp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: temp.path)
        defer { try? FileManager.default.removeItem(at: temp) }

        try run("/usr/sbin/visudo", arguments: ["-cf", temp.path])

        fputs("Mac password for \(user) (sudo) - input is hidden:\n", stderr)
        let password = try SecureInput.readSecret(prompt: "Password: ")
        guard !password.isEmpty else { throw VPNError.connectFailed("Empty password - cancelled.") }
        defer { invalidateCredentialCache() }

        let destination = AppPaths.privilegedRuntimeDirectory
        try runSudo("/bin/mkdir", arguments: ["-p", destination], password: password)
        // Secure any existing tree before updating it, then enforce the same
        // ownership and mode again after all files have been copied.
        try runSudo("/usr/sbin/chown", arguments: ["-R", "root:wheel", destination])
        try runSudo("/bin/chmod", arguments: ["-R", "go-w", destination])
        try runSudo("/usr/bin/ditto", arguments: [runtimeSource, "\(destination)/openconnect"])
        try runSudo("/bin/cp", arguments: [helperSource, AppPaths.privilegedHelperPath])
        try runSudo("/usr/sbin/chown", arguments: ["-R", "root:wheel", destination])
        try runSudo("/bin/chmod", arguments: ["-R", "go-w", destination])
        try runSudo("/bin/chmod", arguments: ["755", AppPaths.privilegedHelperPath])
        try runSudo("/bin/cp", arguments: [temp.path, "/etc/sudoers.d/uoa-proxy"])
        try runSudo("/usr/sbin/chown", arguments: ["root:wheel", "/etc/sudoers.d/uoa-proxy"])
        try runSudo("/bin/chmod", arguments: ["440", "/etc/sudoers.d/uoa-proxy"])

        guard isPasswordlessSudoAvailable() else {
            throw VPNError.connectFailed(
                "Privileged runner was installed, but its passwordless probe failed. Check /etc/sudoers.d/uoa-proxy."
            )
        }
    }

    /// Whether the fixed helper and bundled runtime can run without a password.
    public static func isPasswordlessSudoAvailable(
        openconnectPath _: String = VPNConfig.load().openconnectPath,
        timeout: TimeInterval = 5
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: AppPaths.privilegedHelperPath) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", AppPaths.privilegedHelperPath, "probe"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public static func invalidateCredentialCache() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-k"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPNError.connectFailed("\(executable) failed (exit \(process.terminationStatus)).")
        }
    }

    private static func runSudo(
        _ executable: String,
        arguments: [String],
        password: String? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = password == nil
            ? ["-n", executable] + arguments
            : ["-S", "-p", "", executable] + arguments
        let input = Pipe()
        if password != nil { process.standardInput = input }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        if let password {
            input.fileHandleForWriting.write(Data("\(password)\n".utf8))
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPNError.connectFailed("Privileged install step failed: \(executable) (exit \(process.terminationStatus)).")
        }
    }
}
