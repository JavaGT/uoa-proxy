import Darwin
import Foundation

/// Exclusive ownership of the control daemon via `flock` on `daemon.lock`.
///
/// Only the lock holder may remove/bind the control socket. Contending starters
/// must not kill the holder — they either attach to a live daemon or exit.
public enum DaemonOwnership {
    private static var lockFD: Int32 = -1

    /// Try to acquire the exclusive daemon lock (non-blocking).
    /// Returns `true` if this process now owns the daemon role.
    @discardableResult
    public static func tryAcquire() -> Bool {
        if lockFD >= 0 { return true }

        let path = AppPaths.daemonLockURL.path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return false }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        // Truncate and record our pid for diagnostics only (not authoritative).
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        let payload = "\(getpid())\n"
        _ = payload.withCString { cstr in
            write(fd, cstr, strlen(cstr))
        }

        lockFD = fd
        return true
    }

    public static func release() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    public static var isHeldByThisProcess: Bool {
        lockFD >= 0
    }

    /// Best-effort: whether *some* process currently holds the lock.
    public static func isHeldByAnyone() -> Bool {
        if lockFD >= 0 { return true }
        let path = AppPaths.daemonLockURL.path
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            return true
        }
        _ = flock(fd, LOCK_UN)
        return false
    }
}
