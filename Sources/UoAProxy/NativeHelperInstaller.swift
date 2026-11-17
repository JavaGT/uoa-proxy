import CryptoKit
import Darwin
import Foundation
import UoAProxyCore

/// Asks macOS to authorize only a fixed installation script. The script copies
/// and hashes each bundled file into a root-only staging directory before use.
enum NativeHelperInstaller {
    static func install() throws {
        let user = NSUserName()
        guard !user.isEmpty, user.utf8.allSatisfy({ byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95
        }) else {
            throw IPCError.commandFailed("Cannot safely install for this account name.")
        }
        guard let resources = Bundle.main.resourceURL else { throw IPCError.commandFailed("App resources are missing.") }
        let helper = resources.appendingPathComponent("bin/uoa-proxy-helper")
        let runtime = resources.appendingPathComponent("share/uoa-proxy/openconnect", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: runtime, includingPropertiesForKeys: nil) else {
            throw IPCError.commandFailed("The bundled VPN runtime is missing.")
        }
        var files: [(URL, String, String, Bool)] = []
        func add(_ source: URL, _ destination: String) throws {
            var info = stat()
            guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw IPCError.commandFailed("Invalid installation file: \(source.lastPathComponent)")
            }
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append((source, destination, hash, (info.st_mode & 0o111) != 0))
        }
        try add(helper, "uoa-proxy-helper")
        while let url = enumerator.nextObject() as? URL {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw IPCError.commandFailed("Cannot inspect VPN runtime.") }
            if (info.st_mode & S_IFMT) == S_IFDIR { continue }
            let relative = String(url.path.dropFirst(runtime.path.count + 1))
            guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw IPCError.commandFailed("Invalid runtime path.") }
            try add(url, "openconnect/\(relative)")
        }
        guard files.count > 1 else { throw IPCError.commandFailed("The bundled VPN runtime is empty.") }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var script = """
        set -eu
        umask 077
        /bin/mkdir -p /Library/PrivilegedHelperTools
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.uoa-proxy.XXXXXXXX)
        backup=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.uoa-proxy-backup.XXXXXXXX)
        /bin/rmdir "$backup"
        rule=""
        replaced=0
        cleanup() {
          status=$?
          trap - EXIT
          if [ "$status" -ne 0 ]; then
            if [ -e "$backup" ] || [ -L "$backup" ]; then
              /bin/rm -rf \(quote(AppPaths.privilegedRuntimeDirectory))
              /bin/mv "$backup" \(quote(AppPaths.privilegedRuntimeDirectory)) || status=1
            elif [ "$replaced" -eq 1 ]; then
              /bin/rm -rf \(quote(AppPaths.privilegedRuntimeDirectory))
            fi
          else
            /bin/rm -rf "$backup"
          fi
          /bin/rm -rf "$stage"
          [ -z "$rule" ] || /bin/rm -f "$rule"
          exit "$status"
        }
        trap cleanup EXIT
        rule=$(/usr/bin/mktemp /etc/sudoers.d/.uoa-proxy.XXXXXXXX)
        """
        for (source, destination, hash, executable) in files {
            let parent = (destination as NSString).deletingLastPathComponent
            // Single-quote relative paths separately so $stage is the only expansion.
            let dst = "\"$stage\"/" + quote(destination)
            if !parent.isEmpty { script += "\n/bin/mkdir -p \"$stage\"/\(quote(parent))" }
            script += "\n/bin/cp -- \(quote(source.path)) \(dst)"
            script += "\n[ \"$(/usr/bin/shasum -a 256 \(dst) | /usr/bin/awk '{print $1}')\" = \(quote(hash)) ]"
            script += "\n/bin/chmod \(executable ? "755" : "644") \(dst)"
        }
        let rule = "# UoA Proxy fixed VPN runner\n\(user) ALL=(root) NOPASSWD: \(AppPaths.privilegedHelperPath)\n"
        script += """

        /usr/sbin/chown -R root:wheel "$stage"
        /bin/chmod -R a+rX "$stage"
        /bin/chmod 755 "$stage"
        /usr/bin/printf %s \(quote(rule)) > "$rule"
        /usr/sbin/chown root:wheel "$rule"
        /bin/chmod 440 "$rule"
        /usr/sbin/visudo -cf "$rule" >/dev/null
        if [ -e \(quote(AppPaths.privilegedRuntimeDirectory)) ] || [ -L \(quote(AppPaths.privilegedRuntimeDirectory)) ]; then
          /bin/mv \(quote(AppPaths.privilegedRuntimeDirectory)) "$backup"
        fi
        /bin/mv "$stage" \(quote(AppPaths.privilegedRuntimeDirectory))
        replaced=1
        /bin/mv -f "$rule" /etc/sudoers.d/uoa-proxy
        """
        // AppleScript receives a literal, never source assembled from unescaped paths.
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with prompt \"UoA Proxy needs administrator permission to install its VPN helper.\" with administrator privileges"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if DaemonLifecycle.isDaemonResponsive() {
            let status = try DaemonClient(autoStart: false).status()
            guard status.state == .disconnected else {
                throw IPCError.commandFailed("Disconnect before installing the VPN helper.")
            }
        }
        try DaemonLifecycle.stopDaemon()
        guard DaemonOwnership.tryAcquire() else {
            throw IPCError.commandFailed("The VPN daemon restarted during setup. Try again.")
        }
        defer { DaemonOwnership.release() }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            if message.contains("-128") { throw IPCError.commandFailed("Installation cancelled.") }
            throw IPCError.commandFailed("VPN helper installation failed: \(message)")
        }
    }
}
