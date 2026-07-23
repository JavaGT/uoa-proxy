import Darwin
import Foundation
import UoAProxyCore

@main
enum UoAProxyD {
    /// Soft cap on concurrent client handlers to avoid unbounded task growth.
    private static let maxConcurrentClients = 16

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(
                """
                uoa-proxyd — UoA VPN control daemon

                Usage:
                  uoa-proxyd              Run in foreground (LaunchAgent)
                  uoa-proxyd --daemonize  Fork to background
                  uoa-proxyd --help

                Control socket: \(AppPaths.socketURL.path)
                """
            )
            return
        }

        if args.contains("--daemonize") {
            // Re-exec in background via nohup (safe with Swift runtime; works over SSH).
            // Do NOT kill other daemons here — the child acquires the flock or exits.
            spawnBackgroundAndExit()
            return
        }

        // Atomic singleton: only the lock holder may bind the control socket.
        if !DaemonOwnership.tryAcquire() {
            if DaemonLifecycle.isDaemonResponsive() {
                appendDaemonLog("another instance owns lock and is responsive; exiting pid=\(getpid())")
                exit(0)
            }
            // Grace period for a peer still starting.
            for _ in 0..<20 {
                if DaemonLifecycle.isDaemonResponsive() {
                    exit(0)
                }
                usleep(100_000)
            }
            fputs("uoa-proxyd: lock held by another process that is not responding\n", stderr)
            appendDaemonLog("lock contended and peer unresponsive; exiting pid=\(getpid())")
            exit(1)
        }

        // We own the lock — safe to replace a stale socket path.
        UnixSocket.removeSocketFile(at: AppPaths.socketURL.path)
        writeDaemonPid()
        appendDaemonLog("uoa-proxyd starting pid=\(getpid())")

        defer {
            UnixSocket.removeSocketFile(at: AppPaths.socketURL.path)
            DaemonOwnership.release()
            appendDaemonLog("uoa-proxyd stopped pid=\(getpid())")
        }

        let service = VPNService()
        _ = await service.snapshot()

        // Ignore SIGPIPE; sockets also set SO_NOSIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                Task {
                    await service.shutdown()
                    UnixSocket.removeSocketFile(at: AppPaths.socketURL.path)
                    DaemonOwnership.release()
                    appendDaemonLog("uoa-proxyd stopped by signal pid=\(getpid())")
                    exit(0)
                }
            }
            source.resume()
            return source
        }
        defer { terminationSources.forEach { $0.cancel() } }

        do {
            try await runServer(service: service)
        } catch {
            fputs("uoa-proxyd error: \(error.localizedDescription)\n", stderr)
            appendDaemonLog("fatal: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func spawnBackgroundAndExit() {
        let binary = CommandLine.arguments[0]
        let logPath = AppPaths.daemonLogURL.path
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        // If a daemon is already healthy, do nothing.
        if DaemonLifecycle.isDaemonResponsive() {
            fputs("uoa-proxyd already running\n", stderr)
            exit(0)
        }

        let escapedBin = binary.replacingOccurrences(of: "'", with: "'\\''")
        let escapedLog = logPath.replacingOccurrences(of: "'", with: "'\\''")
        let shell = "nohup '\(escapedBin)' >>'\(escapedLog)' 2>&1 & echo $!"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", shell]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if let pidText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !pidText.isEmpty {
                // Diagnostic only — lock ownership is authoritative.
                try? pidText.write(to: AppPaths.daemonPidURL, atomically: true, encoding: .utf8)
                fputs("uoa-proxyd started in background (pid \(pidText))\n", stderr)
            }
        } catch {
            fputs("failed to daemonize: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        for _ in 0..<50 {
            if DaemonLifecycle.isDaemonResponsive() {
                exit(0)
            }
            usleep(100_000)
        }
        fputs("warning: control socket not ready yet\n", stderr)
        exit(0)
    }

    private static func writeDaemonPid() {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? pid.write(to: AppPaths.daemonPidURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: AppPaths.daemonPidURL.path
        )
    }

    private static func appendDaemonLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        let path = AppPaths.daemonLogURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        _ = try? fh.seekToEnd()
        fh.write(Data(text.utf8))
    }

    private static func runServer(service: VPNService) async throws {
        let path = AppPaths.socketURL.path
        let listenFD = try UnixSocket.listen(path: path)
        defer { UnixSocket.close(listenFD) }
        FileHandle.standardError.write(Data("listening on \(path)\n".utf8))
        appendDaemonLog("listening on \(path)")

        let gate = ClientGate(limit: maxConcurrentClients)

        while true {
            let clientFD: Int32
            do {
                clientFD = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let fd = try UnixSocket.accept(listenFD)
                            cont.resume(returning: fd)
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
            } catch {
                // Transient accept errors should not kill the daemon.
                appendDaemonLog("accept error: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            // Bound concurrent handlers; drop excess clients quickly.
            guard await gate.tryEnter() else {
                let busy = IPCResponse(
                    id: "?",
                    ok: false,
                    state: .disconnected,
                    message: "Busy",
                    error: "daemon too busy; retry"
                )
                if let encoded = try? JSONEncoder().encode(busy),
                   let out = String(data: encoded, encoding: .utf8) {
                    try? UnixSocket.writeLine(clientFD, out)
                }
                UnixSocket.close(clientFD)
                continue
            }

            Task {
                defer {
                    Task { await gate.leave() }
                }
                await handleClient(fd: clientFD, service: service)
            }
        }
    }

    private static func handleClient(fd: Int32, service: VPNService) async {
        defer { UnixSocket.close(fd) }
        // Short default; connect/disconnect handlers may run long but the
        // client sets its own receive timeout on its end.
        UnixSocket.setIOTimeouts(fd, seconds: 95)
        do {
            let line = try UnixSocket.readLine(fd)
            guard let data = line.data(using: .utf8) else {
                return
            }
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            let started = Date()
            let response = await process(request: request, service: service)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if request.cmd != .ping, request.cmd != .status {
                appendDaemonLog(
                    "req id=\(request.id) cmd=\(request.cmd.rawValue) ok=\(response.ok) state=\(response.state.rawValue) \(ms)ms"
                )
            }
            let encoded = try JSONEncoder().encode(response)
            guard let out = String(data: encoded, encoding: .utf8) else { return }
            try UnixSocket.writeLine(fd, out)
            if request.cmd == .shutdown {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    _ = kill(getpid(), SIGTERM)
                }
            }
        } catch {
            appendDaemonLog("client error: \(error.localizedDescription)")
            let fallback = IPCResponse(
                id: "?",
                ok: false,
                state: .disconnected,
                message: "Error",
                error: error.localizedDescription
            )
            if let encoded = try? JSONEncoder().encode(fallback),
               let out = String(data: encoded, encoding: .utf8) {
                try? UnixSocket.writeLine(fd, out)
            }
        }
    }

    private static func process(request: IPCRequest, service: VPNService) async -> IPCResponse {
        switch request.cmd {
        case .ping:
            return await makeResponse(id: request.id, service: service, ok: true)

        case .status, .otp, .getConfig:
            return await makeResponse(id: request.id, service: service, ok: true)

        case .connect:
            await service.connect()
            let snap = await service.snapshot()
            return fill(IPCResponse(
                id: request.id,
                ok: snap.state == .connected,
                state: snap.state,
                message: snap.message,
                error: snap.state == .connected ? nil : snap.error
            ), snap: snap)

        case .disconnect:
            await service.disconnect()
            for _ in 0..<40 {
                let snap = await service.snapshot()
                if snap.state != .disconnecting { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let snap = await service.snapshot()
            return fill(IPCResponse(
                id: request.id,
                ok: snap.state == .disconnected,
                state: snap.state,
                message: snap.message,
                error: snap.error
            ), snap: snap)

        case .toggle:
            let before = await service.snapshot()
            if before.state == .connected || before.state == .connecting {
                await service.disconnect()
            } else {
                await service.connect()
            }
            let snap = await service.snapshot()
            return fill(IPCResponse(
                id: request.id,
                ok: snap.error == nil || snap.state == .connected || snap.state == .disconnected,
                state: snap.state,
                message: snap.message,
                error: snap.error
            ), snap: snap)

        case .shutdown:
            await service.shutdown()
            let snap = await service.snapshot()
            return fill(IPCResponse(
                id: request.id,
                ok: true,
                state: snap.state,
                message: "Shutting down"
            ), snap: snap)

        case .setConfig:
            var config = VPNConfig.load()
            if let v = request.username { config.username = v }
            if let v = request.server { config.server = v }
            if let v = request.openconnectPath { config.openconnectPath = v }
            if let v = request.protocolName { config.protocolName = v }
            await service.setConfig(config)
            return await makeResponse(id: request.id, service: service, ok: true)

        case .setPassword:
            do {
                try await service.setPassword(request.password ?? "")
                return await makeResponse(id: request.id, service: service, ok: true)
            } catch {
                return await makeResponse(id: request.id, service: service, ok: false, error: error.localizedDescription)
            }

        case .setTOTPSecret:
            do {
                try await service.setTOTPSecret(request.totpSecret ?? "")
                return await makeResponse(id: request.id, service: service, ok: true)
            } catch {
                return await makeResponse(id: request.id, service: service, ok: false, error: error.localizedDescription)
            }

        case .clearPassword:
            do {
                try await service.setPassword("")
                return await makeResponse(id: request.id, service: service, ok: true)
            } catch {
                return await makeResponse(id: request.id, service: service, ok: false, error: error.localizedDescription)
            }

        case .clearTOTPSecret:
            do {
                try await service.setTOTPSecret("")
                return await makeResponse(id: request.id, service: service, ok: true)
            } catch {
                return await makeResponse(id: request.id, service: service, ok: false, error: error.localizedDescription)
            }
        }
    }

    private static func makeResponse(
        id: String,
        service: VPNService,
        ok: Bool,
        error: String? = nil
    ) async -> IPCResponse {
        let snap = await service.snapshot()
        return fill(
            IPCResponse(
                id: id,
                ok: ok,
                state: snap.state,
                message: snap.message,
                error: error ?? snap.error
            ),
            snap: snap
        )
    }

    private static func fill(_ response: IPCResponse, snap: ServiceSnapshot) -> IPCResponse {
        var r = response
        r.username = snap.config.username
        r.server = snap.config.server
        r.openconnectPath = snap.config.openconnectPath
        r.protocolName = snap.config.protocolName
        r.hasPassword = snap.hasPassword
        r.hasTOTPSecret = snap.hasTOTPSecret
        r.otp = snap.otp
        r.otpSecondsRemaining = snap.otpSecondsRemaining
        r.sudoOK = snap.sudoOK
        r.daemonPID = snap.daemonPID
        return r
    }
}

/// Limits concurrent IPC handlers without blocking the async accept loop.
private actor ClientGate {
    private let limit: Int
    private var active = 0

    init(limit: Int) {
        self.limit = limit
    }

    func tryEnter() -> Bool {
        guard active < limit else { return false }
        active += 1
        return true
    }

    func leave() {
        if active > 0 { active -= 1 }
    }
}
