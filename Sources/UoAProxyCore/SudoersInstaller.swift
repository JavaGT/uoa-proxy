import Darwin
import CryptoKit
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
            throw VPNError.connectFailed("Bundled openconnect runtime is missing from this uoa-proxy installation.")
        }
        let sourceDigest = try digestInstallSources(helper: helperSource, runtime: runtimeSource)

        let contents = """
        # UoA Proxy - fixed, validating privileged VPN runner only
        # Managed by uoa-proxy
        \(user) ALL=(root) NOPASSWD: \(AppPaths.privilegedHelperPath)

        """
        fputs("Mac password for \(user) (sudo) - input is hidden:\n", stderr)
        let password = try SecureInput.readSecret(prompt: "Password: ")
        guard !password.isEmpty else { throw VPNError.connectFailed("Empty password - cancelled.") }
        guard !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            throw VPNError.connectFailed("Mac password cannot contain a line break.")
        }
        defer { invalidateCredentialCache() }

        let destination = AppPaths.privilegedRuntimeDirectory
        let installID = UUID().uuidString
        let stagedRuntime = "/Library/PrivilegedHelperTools/.uoa-proxy-\(installID)"
        let stagedSudoers = "/etc/sudoers.d/.uoa-proxy-\(installID)"
        defer {
            try? runSudo("/bin/rm", arguments: ["-rf", stagedRuntime])
            try? runSudo("/bin/rm", arguments: ["-f", stagedSudoers])
        }

        // Authenticate once, then create and validate sudoers content entirely
        // under the root-only destination directory. No user-writable pathname
        // is reused after visudo validates it.
        invalidateCredentialCache()
        try runSudo("/usr/bin/true", arguments: [], password: password)
        // Authenticate before stopping a live connection, and never replace
        // the runtime underneath a daemon that may own a tunnel.
        try DaemonLifecycle.stopDaemon()
        // Create the parent as well: a clean Mac has no PrivilegedHelperTools yet.
        try runSudo("/bin/mkdir", arguments: ["-p", "-m", "700", stagedRuntime])
        try runSudo("/usr/bin/ditto", arguments: [runtimeSource, "\(stagedRuntime)/openconnect"])
        try runSudo("/bin/cp", arguments: [helperSource, "\(stagedRuntime)/uoa-proxy-helper"])
        try runSudo("/usr/sbin/chown", arguments: ["-R", "root:wheel", stagedRuntime])
        // An inherited ACL can keep a group/other write grant visible in the
        // effective mode even after `go-w`. Strip ACLs first, then force
        // deterministic modes rather than trusting the source tree.
        try runSudo("/bin/chmod", arguments: ["-R", "-N", stagedRuntime])
        try runSudo("/bin/chmod", arguments: ["-R", "go-w", stagedRuntime])
        try runSudo("/bin/chmod", arguments: ["-R", "u+rwX", stagedRuntime])
        // The unprivileged verifier and availability probe need traversal;
        // the root-owned directory remains unwritable by other users.
        try runSudo("/bin/chmod", arguments: [StagedInstallPermissions.stagedDirectory, stagedRuntime])
        try runSudo("/bin/chmod", arguments: [StagedInstallPermissions.helper, "\(stagedRuntime)/uoa-proxy-helper"])
        try runSudo("/bin/chmod", arguments: [StagedInstallPermissions.executable, "\(stagedRuntime)/openconnect/bin/openconnect"])
        try runSudo("/bin/chmod", arguments: [StagedInstallPermissions.executable, "\(stagedRuntime)/openconnect/vpnc-script"])
        guard try digestInstallSources(
            helper: "\(stagedRuntime)/uoa-proxy-helper",
            runtime: "\(stagedRuntime)/openconnect"
        ) == sourceDigest,
        try digestInstallSources(helper: helperSource, runtime: runtimeSource) == sourceDigest else {
            throw VPNError.connectFailed("uoa-proxy installation artifacts changed while they were being installed.")
        }
        try runSudo("/usr/bin/tee", arguments: [stagedSudoers], input: Data(contents.utf8))
        try runSudo("/usr/sbin/chown", arguments: ["root:wheel", stagedSudoers])
        try runSudo("/bin/chmod", arguments: ["440", stagedSudoers])
        try runSudo("/usr/sbin/visudo", arguments: ["-cf", stagedSudoers])

        try runSudo("/bin/rm", arguments: ["-rf", destination])
        try runSudo("/bin/mv", arguments: [stagedRuntime, destination])
        try runSudo("/bin/mv", arguments: ["-f", stagedSudoers, "/etc/sudoers.d/uoa-proxy"])

        invalidateCredentialCache()
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

    private static func digestInstallSources(helper: String, runtime: String) throws -> SHA256.Digest {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: runtime, isDirectory: true)
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw VPNError.connectFailed("Cannot inspect the bundled OpenConnect runtime.")
        }
        var files = [(name: "helper", path: helper)]
        while let url = enumerator.nextObject() as? URL {
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                throw VPNError.connectFailed("Cannot inspect install source: \(url.path)")
            }
            if (info.st_mode & S_IFMT) == S_IFDIR { continue }
            files.append((name: "runtime/\(relative)", path: url.path))
        }
        files.sort { $0.name < $1.name }

        var digest = SHA256()
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0 else {
                throw VPNError.connectFailed("Cannot inspect install source: \(file.path)")
            }
            guard StagedInstallPermissions.isSafe(info.st_mode) else {
                let mode = String(format: "%o", info.st_mode & 0o7777)
                throw VPNError.connectFailed(
                    "Install source must be a regular file without group/other write: \(file.path) (mode \(mode))"
                )
            }
            digest.update(data: Data(file.name.utf8))
            digest.update(data: try Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe))
        }
        return digest.finalize()
    }

    private static func runSudo(
        _ executable: String,
        arguments: [String],
        password: String? = nil,
        input data: Data? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = password == nil
            ? ["-n", executable] + arguments
            : ["-S", "-p", "", executable] + arguments
        let input = Pipe()
        if password != nil || data != nil { process.standardInput = input }
        process.standardOutput = executable == "/usr/bin/tee" ? FileHandle.nullDevice : FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        if let password {
            input.fileHandleForWriting.write(Data("\(password)\n".utf8))
            try? input.fileHandleForWriting.close()
        } else if let data {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VPNError.connectFailed("Privileged install step failed: \(executable) (exit \(process.terminationStatus)).")
        }
    }
}
