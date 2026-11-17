import Darwin

/// POSIX policy for files staged before the privileged VPN helper is installed.
///
/// The installer hashes every staged artefact before moving it into place, and
/// the root helper re-checks the installed tree at startup. Both reject files
/// that other users can write, so staging must normalise permissions explicitly
/// instead of relying on the source tree or on inherited ACLs.
public enum StagedInstallPermissions {
    public static let stagedDirectory = "755"
    public static let helper = "755"
    public static let executable = "755"
    public static let data = "444"

    /// Whether `mode` describes a regular file that no unprivileged user can write.
    public static func isSafe(_ mode: mode_t) -> Bool {
        (mode & S_IFMT) == S_IFREG && (mode & 0o022) == 0
    }
}
