import Darwin
import Foundation

/// Interactive terminal input helpers.
/// Prefer `/dev/tty` so prompts work even when stdin is redirected.
public enum SecureInput {
    public static func readLine(prompt: String, default defaultValue: String? = nil) throws -> String {
        let suffix: String
        if let defaultValue, !defaultValue.isEmpty {
            suffix = " [\(defaultValue)]: "
        } else {
            suffix = ": "
        }
        FileHandle.standardError.write(Data((prompt + suffix).utf8))

        let line = try readRawLine(echo: true).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty, let defaultValue {
            return defaultValue
        }
        return line
    }

    public static func readSecret(prompt: String) throws -> String {
        FileHandle.standardError.write(Data(prompt.utf8))
        return try readRawLine(echo: false)
    }

    public static func confirm(prompt: String, defaultYes: Bool = true) throws -> Bool {
        let hint = defaultYes ? "Y/n" : "y/N"
        FileHandle.standardError.write(Data("\(prompt) [\(hint)]: ".utf8))
        let line = try readRawLine(echo: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if line.isEmpty { return defaultYes }
        return line == "y" || line == "yes"
    }

    private static func readRawLine(echo: Bool) throws -> String {
        let ttyFD = open("/dev/tty", O_RDWR | O_NOCTTY)
        let fd: Int32
        let closeWhenDone: Bool
        if ttyFD >= 0 {
            fd = ttyFD
            closeWhenDone = true
        } else if isatty(STDIN_FILENO) != 0 {
            fd = STDIN_FILENO
            closeWhenDone = false
        } else {
            throw SecureInputError.noTerminal
        }
        defer {
            if closeWhenDone {
                close(fd)
            }
        }

        var original = termios()
        var didSetTerm = false
        if !echo {
            guard tcgetattr(fd, &original) == 0 else {
                throw SecureInputError.terminalControl("tcgetattr failed")
            }
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            hidden.c_lflag |= tcflag_t(ECHONL)
            guard tcsetattr(fd, TCSAFLUSH, &hidden) == 0 else {
                throw SecureInputError.terminalControl("tcsetattr failed")
            }
            didSetTerm = true
        }
        defer {
            if didSetTerm {
                _ = tcsetattr(fd, TCSAFLUSH, &original)
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }

        var buffer = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n == 0 {
                break
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SecureInputError.readFailed(errno)
            }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                break
            }
            if byte == 0x7f || byte == 0x08 {
                if !buffer.isEmpty { buffer.removeLast() }
                continue
            }
            buffer.append(byte)
            if buffer.count > 4096 {
                throw SecureInputError.tooLong
            }
        }

        guard let line = String(bytes: buffer, encoding: .utf8) else {
            throw SecureInputError.invalidUTF8
        }
        return line
    }
}

public enum SecureInputError: LocalizedError {
    case noTerminal
    case terminalControl(String)
    case readFailed(Int32)
    case tooLong
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .noTerminal:
            return "No terminal available for hidden password entry. Run from an interactive SSH/Terminal session."
        case .terminalControl(let detail):
            return "Could not control terminal echo: \(detail)"
        case .readFailed(let code):
            return "Read failed: \(String(cString: strerror(code)))"
        case .tooLong:
            return "Input too long."
        case .invalidUTF8:
            return "Input was not valid UTF-8."
        }
    }
}
