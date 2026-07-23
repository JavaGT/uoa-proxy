import Darwin
import Foundation

private let installDirectory = "/Library/PrivilegedHelperTools/nz.ac.auckland.uoa-proxy"
private let openconnectPath = "\(installDirectory)/openconnect/bin/openconnect"
private let vpncScriptPath = "\(installDirectory)/openconnect/vpnc-script"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("uoa-proxy-helper: \(message)\n".utf8))
    exit(64)
}

private func requireRootOwnedFile(_ path: String, executable: Bool) {
    var info = stat()
    guard lstat(path, &info) == 0 else { fail("missing installed runtime: \(path)") }
    guard (info.st_mode & S_IFMT) == S_IFREG else { fail("runtime is not a regular file: \(path)") }
    guard info.st_uid == 0, (info.st_mode & 0o022) == 0 else {
        fail("runtime must be root-owned and not group/other-writable: \(path)")
    }
    if executable, (info.st_mode & 0o111) == 0 { fail("runtime is not executable: \(path)") }
}

private func requireRootOwnedDirectory(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == 0,
          (info.st_mode & 0o022) == 0 else {
        fail("runtime directory must be root-owned and not group/other-writable: \(path)")
    }
}

private func validateRuntime() {
    let runtime = "\(installDirectory)/openconnect"
    let libraryDirectory = "\(runtime)/lib"
    for directory in [installDirectory, runtime, "\(runtime)/bin", libraryDirectory] {
        requireRootOwnedDirectory(directory)
    }
    requireRootOwnedFile(openconnectPath, executable: true)
    requireRootOwnedFile(vpncScriptPath, executable: true)
    guard let libraries = try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory),
          !libraries.isEmpty else {
        fail("bundled library directory is empty")
    }
    for library in libraries {
        requireRootOwnedFile("\(libraryDirectory)/\(library)", executable: false)
    }
}

private func isValidUsername(_ value: String) -> Bool {
    guard (1...64).contains(value.utf8.count) else { return false }
    return value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
    }
}

private func normalizedServer(_ value: String) -> String? {
    let allowed = [
        "connectvpn.auckland.ac.nz/client",
        "https://connectvpn.auckland.ac.nz/client"
    ]
    return allowed.contains(value) ? value : nil
}

private func execOpenconnect(username: String, server: String) -> Never {
    validateRuntime()
    guard geteuid() == 0 else { fail("must run as root") }
    guard isValidUsername(username) else { fail("invalid University username") }
    guard let server = normalizedServer(server) else { fail("server is not the University VPN gateway") }

    let arguments = [
        openconnectPath,
        "--protocol=fortinet",
        "--user=\(username)",
        "--passwd-on-stdin",
        "--non-inter",
        "--reconnect-timeout=30",
        "--script=\(vpncScriptPath)",
        server
    ]
    let environment = [
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME=/var/empty",
        "LANG=en_US.UTF-8"
    ]

    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    var mutableArgv = argv
    var mutableEnvp = envp
    execve(openconnectPath, &mutableArgv, &mutableEnvp)
    fail("exec failed: \(String(cString: strerror(errno)))")
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["probe"] {
    guard geteuid() == 0 else { fail("must run as root") }
    validateRuntime()
    print("ready")
} else if arguments.count == 5,
          arguments[0] == "connect",
          arguments[1] == "--user",
          arguments[3] == "--server" {
    execOpenconnect(username: arguments[2], server: arguments[4])
} else {
    fail("expected: probe | connect --user USER --server connectvpn.auckland.ac.nz/client")
}
