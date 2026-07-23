import Darwin
import Foundation

/// Minimal AF_UNIX stream helpers (newline-delimited JSON frames).
public enum UnixSocket {
    public static func removeSocketFile(at path: String) {
        if FileManager.default.fileExists(atPath: path) {
            unlink(path)
        }
    }

    public static func listen(path: String, backlog: Int32 = 8) throws -> Int32 {
        // Caller must hold DaemonOwnership before removing a live path.
        removeSocketFile(at: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.system("socket()", errno)
        }
        applyCommonOptions(fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try fillPath(&addr, path: path, fd: fd)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw SocketError.system("bind()", err)
        }

        // Owner-only access
        chmod(path, 0o600)

        guard Darwin.listen(fd, backlog) == 0 else {
            let err = errno
            close(fd)
            removeSocketFile(at: path)
            throw SocketError.system("listen()", err)
        }

        return fd
    }

    /// Accept a client. Retries `EINTR` / `ECONNABORTED` so transient signals are not fatal.
    public static func accept(_ listenFD: Int32) throws -> Int32 {
        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client >= 0 {
                applyCommonOptions(client)
                return client
            }
            let err = errno
            if err == EINTR || err == ECONNABORTED {
                continue
            }
            throw SocketError.system("accept()", err)
        }
    }

    public static func connect(path: String, timeout: TimeInterval = 3) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SocketError.system("socket()", errno)
        }
        applyCommonOptions(fd)
        setIOTimeouts(fd, seconds: timeout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        do {
            try fillPath(&addr, path: path, fd: fd)
        } catch {
            close(fd)
            throw error
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw SocketError.system("connect()", err)
        }
        // Re-apply timeouts after connect (some platforms only honor them post-connect).
        setIOTimeouts(fd, seconds: timeout)
        return fd
    }

    public static func writeLine(_ fd: Int32, _ line: String) throws {
        var payload = line
        if !payload.hasSuffix("\n") {
            payload += "\n"
        }
        try payload.withCString { cstr in
            let len = strlen(cstr)
            var written = 0
            while written < len {
                let n = Darwin.write(fd, cstr + written, len - written)
                if n == 0 {
                    throw SocketError.closed
                }
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw SocketError.timeout("write")
                    }
                    throw SocketError.system("write()", errno)
                }
                written += n
            }
        }
    }

    public static func readLine(_ fd: Int32, maxBytes: Int = 1_048_576) throws -> String {
        var buffer = [UInt8]()
        buffer.reserveCapacity(min(maxBytes, 4096))
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buffer.count < maxBytes {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 {
                if buffer.isEmpty {
                    throw SocketError.closed
                }
                break
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw SocketError.timeout("read")
                }
                throw SocketError.system("read()", errno)
            }

            for i in 0..<n {
                let byte = chunk[i]
                if byte == UInt8(ascii: "\n") {
                    // Ignore any trailing bytes after the frame delimiter.
                    guard let line = String(bytes: buffer, encoding: .utf8) else {
                        throw SocketError.protocolError("invalid UTF-8")
                    }
                    return line
                }
                buffer.append(byte)
                if buffer.count >= maxBytes {
                    throw SocketError.frameTooLarge
                }
            }
        }
        throw SocketError.frameTooLarge
    }

    public static func close(_ fd: Int32) {
        Darwin.close(fd)
    }

    // MARK: - Options

    private static func applyCommonOptions(_ fd: Int32) {
        var on: Int32 = 1
        // Prevent client SIGPIPE death when the daemon restarts mid-write.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Close-on-exec so we don't leak FDs into openconnect/sudo children.
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    public static func setIOTimeouts(_ fd: Int32, seconds: TimeInterval) {
        let whole = max(0, Int(seconds))
        let micros = max(0, Int((seconds - Double(whole)) * 1_000_000))
        var tv = timeval(tv_sec: whole, tv_usec: Int32(micros))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func fillPath(_ addr: inout sockaddr_un, path: String, fd: Int32) throws {
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw SocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() {
                buf[i] = UInt8(bitPattern: b)
            }
        }
    }
}

public enum SocketError: LocalizedError {
    case system(String, Int32)
    case pathTooLong
    case closed
    case protocolError(String)
    case timeout(String)
    case frameTooLarge

    public var errorDescription: String? {
        switch self {
        case .system(let op, let code):
            return "\(op) failed: \(String(cString: strerror(code))) (\(code))"
        case .pathTooLong:
            return "Unix socket path is too long."
        case .closed:
            return "Socket closed."
        case .protocolError(let detail):
            return detail
        case .timeout(let op):
            return "Socket \(op) timed out."
        case .frameTooLarge:
            return "IPC frame exceeded size limit without a newline delimiter."
        }
    }
}
