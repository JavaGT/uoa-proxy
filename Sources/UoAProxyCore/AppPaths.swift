import Darwin
import Foundation

/// Shared filesystem locations for daemon, CLI, and menu bar app.
public enum AppPaths {
    public static let serviceName = "nz.ac.auckland.uoa-proxy"
    public static let launchAgentLabel = "nz.ac.auckland.uoa-proxy.daemon"
    public static let privilegedRuntimeDirectory =
        "/Library/PrivilegedHelperTools/nz.ac.auckland.uoa-proxy"
    public static let privilegedHelperPath =
        "\(privilegedRuntimeDirectory)/uoa-proxy-helper"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UoAProxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: dir.path
        )
        return dir
    }

    public static var configFileURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static var socketURL: URL {
        supportDirectory.appendingPathComponent("control.sock")
    }

    public static var openconnectLogURL: URL {
        supportDirectory.appendingPathComponent("openconnect.log")
    }

    public static var daemonLogURL: URL {
        supportDirectory.appendingPathComponent("daemon.log")
    }

    public static var daemonPidURL: URL {
        supportDirectory.appendingPathComponent("daemon.pid")
    }

    public static var daemonLockURL: URL {
        supportDirectory.appendingPathComponent("daemon.lock")
    }

    /// Preferred install locations for binaries (first existing wins for discovery).
    public static var cliSearchPaths: [String] {
        [
            "/usr/local/bin/uoa-proxy",
            "/opt/homebrew/bin/uoa-proxy",
            "\(NSHomeDirectory())/.local/bin/uoa-proxy"
        ]
    }

    public static var daemonSearchPaths: [String] {
        [
            "/usr/local/bin/uoa-proxyd",
            "/opt/homebrew/bin/uoa-proxyd",
            "\(NSHomeDirectory())/.local/bin/uoa-proxyd"
        ]
    }

    public static var supervisorSearchPaths: [String] {
        [
            "/usr/local/bin/uoa-proxy-supervisor",
            "/opt/homebrew/bin/uoa-proxy-supervisor",
            "\(NSHomeDirectory())/.local/bin/uoa-proxy-supervisor"
        ]
    }

    /// Menu bar app bundle search order (first existing wins).
    public static var menuBarAppSearchPaths: [String] {
        [
            "/Applications/UoA Proxy.app",
            "/usr/local/opt/uoa-proxy/Applications/UoA Proxy.app",
            "/opt/homebrew/opt/uoa-proxy/Applications/UoA Proxy.app",
            "\(NSHomeDirectory())/Applications/UoA Proxy.app"
        ]
    }

    public static func resolveDaemonBinary() -> String? {
        for path in daemonSearchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public static func resolveSupervisorBinary() -> String? {
        supervisorSearchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    public static func resolveHelperSource() -> String? {
        guard let prefix = currentInstallPrefix() else { return nil }
        let path = "\(prefix)/bin/uoa-proxy-helper"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public static func resolveOpenconnectRuntimeSource() -> String? {
        guard let prefix = currentInstallPrefix() else { return nil }
        let path = "\(prefix)/share/uoa-proxy/openconnect"
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? path : nil
    }

    /// Resolve companion artifacts from the same installation as this process.
    /// This prevents a stale /usr/local install from being mixed with Homebrew.
    private static func currentInstallPrefix() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
        guard executable.deletingLastPathComponent().lastPathComponent == "bin" else {
            return nil
        }
        return executable.deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Path to `UoA Proxy.app` if installed.
    public static func resolveMenuBarApp() -> String? {
        for path in menuBarAppSearchPaths where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    /// Executable inside the app bundle.
    public static func resolveMenuBarBinary() -> String? {
        guard let app = resolveMenuBarApp() else { return nil }
        let bin = (app as NSString).appendingPathComponent("Contents/MacOS/UoAProxy")
        return FileManager.default.isExecutableFile(atPath: bin) ? bin : nil
    }
}
