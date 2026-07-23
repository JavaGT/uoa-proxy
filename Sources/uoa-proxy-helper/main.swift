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

private func readCredentialLine(maxBytes: Int = 16_384) -> Data {
    var result = Data()
    var byte: UInt8 = 0
    while result.count < maxBytes {
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count == 1 {
            result.append(byte)
            if byte == UInt8(ascii: "\n") { return result }
        } else if count == 0 {
            fail("credential input closed early")
        } else if errno != EINTR {
            fail("cannot read credentials: \(String(cString: strerror(errno)))")
        }
    }
    fail("credential input exceeded size limit")
}

private func writeAll(_ fd: Int32, data: Data) {
    data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno != EINTR {
                fail("cannot forward credentials: \(String(cString: strerror(errno)))")
            }
        }
    }
}

private func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return status }
        if result < 0, errno != EINTR {
            fail("waitpid failed: \(String(cString: strerror(errno)))")
        }
        usleep(100_000)
    }
    return nil
}

private func exitForWaitStatus(_ status: Int32) -> Never {
    let signal = status & 0x7f
    if signal == 0 { exit((status >> 8) & 0xff) }
    if signal != 0x7f { exit(128 + signal) }
    exit(1)
}

private func superviseChild(arguments: [String], environment: [String], input: Data) -> Never {
    var credentialPipe = [Int32](repeating: -1, count: 2)
    guard pipe(&credentialPipe) == 0 else { fail("pipe failed: \(String(cString: strerror(errno)))") }
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    defer {
        argv.dropLast().forEach { free($0) }
        envp.dropLast().forEach { free($0) }
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { fail("cannot initialize child file actions") }
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, credentialPipe[0], STDIN_FILENO)
    posix_spawn_file_actions_addclose(&actions, credentialPipe[0])
    posix_spawn_file_actions_addclose(&actions, credentialPipe[1])

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { fail("cannot initialize child attributes") }
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)

    var child: pid_t = 0
    let spawnResult = posix_spawn(&child, arguments[0], &actions, &attributes, &argv, &envp)
    guard spawnResult == 0 else { fail("spawn failed: \(String(cString: strerror(spawnResult)))") }

    close(credentialPipe[0])
    writeAll(credentialPipe[1], data: input)
    close(credentialPipe[1])

    // The unprivileged daemon owns stdin's write end. EOF is the only stop
    // command and also fires if the daemon crashes, so no reusable PID or
    // general privileged signal surface is needed.
    while true {
        var status: Int32 = 0
        let result = waitpid(child, &status, WNOHANG)
        if result == child { exitForWaitStatus(status) }
        if result < 0, errno != EINTR { fail("waitpid failed: \(String(cString: strerror(errno)))") }

        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        let pollResult = poll(&descriptor, 1, 100)
        if pollResult > 0, (descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
            _ = kill(-child, SIGTERM)
            if let status = waitForExit(child, timeout: 5) { exitForWaitStatus(status) }
            _ = kill(-child, SIGKILL)
            if let status = waitForExit(child, timeout: 2) { exitForWaitStatus(status) }
            fail("owned OpenConnect process did not exit")
        }
    }
}

private func superviseOpenconnect(username: String, server: String) -> Never {
    validateRuntime()
    guard geteuid() == 0 else { fail("must run as root") }
    guard isValidUsername(username) else { fail("invalid University username") }
    guard let server = normalizedServer(server) else { fail("server is not the University VPN gateway") }

    let credentials = readCredentialLine() + readCredentialLine()
    superviseChild(
        arguments: [
            openconnectPath,
            "--protocol=fortinet",
            "--user=\(username)",
            "--passwd-on-stdin",
            "--non-inter",
            "--reconnect-timeout=30",
            "--script=\(vpncScriptPath)",
            server
        ],
        environment: [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=/var/empty",
            "LANG=en_US.UTF-8"
        ],
        input: credentials
    )
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["probe"] {
    guard geteuid() == 0 else { fail("must run as root") }
    validateRuntime()
    print("ready")
} else if arguments == ["self-test-supervision"] {
    // This mode is intentionally unavailable through the root sudoers entry.
    guard geteuid() != 0 else { fail("self-test cannot run as root") }
    superviseChild(
        arguments: ["/bin/sleep", "30"],
        environment: ["PATH=/usr/bin:/bin"],
        input: Data()
    )
} else if arguments.count == 5,
          arguments[0] == "connect",
          arguments[1] == "--user",
          arguments[3] == "--server" {
    superviseOpenconnect(username: arguments[2], server: arguments[4])
} else {
    fail("expected: probe | connect --user USER --server connectvpn.auckland.ac.nz/client")
}
