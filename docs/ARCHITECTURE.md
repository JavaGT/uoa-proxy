# UoA Proxy architecture constraints

This document defines the constraints for replacing heuristic process management
without changing the VPN's current split-tunnel behaviour.

## Required behaviour

- The system MUST provide a kernel-level VPN usable by applications that do not
  support proxies, especially macOS Finder/SMB.
- While connected, `files.auckland.ac.nz` MUST resolve correctly and TCP port
  445 MUST follow a University-provided VPN route so Finder can open
  `smb://files.auckland.ac.nz/research/resart202600017-studentworkandwellbeing`.
- The system MUST preserve routes and DNS settings supplied by the University
  gateway and MUST NOT install a default route unless the gateway explicitly
  supplies one.
- The daemon MUST directly own one foreground `openconnect` process and MUST
  derive connection state only from that owned process.
- The daemon MUST NOT discover, adopt, or signal a process using a PID file,
  process name, executable-name search, or an unverified reusable PID.
- Concurrent connect requests MUST share one attempt; disconnect MUST cancel
  that exact attempt and MUST prevent automatic reconnect until connect is
  requested again.
- A failed, timed-out, or cancelled attempt MUST be reaped before it is reported
  complete and MUST NOT leave a tunnel that can become active later.
- Unexpected tunnel exit while connection is desired MUST trigger one bounded,
  cancellable reconnect loop with exponential backoff. Empty credentials,
  invalid configuration, and authentication rejection MUST stop that loop.
- Empty credentials or configuration MUST fail before a privileged process is
  started. A single successful tunnel process remains a valid connected state.
- Network loss, sleep/wake, daemon shutdown, and child-process failure MUST
  produce a bounded state transition rather than an indefinite IPC operation.
- Only the configured user may control the daemon. Secrets MUST NOT appear in
  command-line arguments or logs, and IPC frames MUST remain size- and
  time-bounded.
- The privileged command surface MUST expose only the operations required to
  run and stop this VPN. It MUST NOT grant passwordless access to arbitrary
  `openconnect`, `kill`, `pkill`, scripts, servers, or executable paths.
- Runtime files MUST live in an owner-only directory and MUST NOT follow
  symlinks or trust files created in a shared temporary directory.
- Reinstallation or upgrade MUST stop the old daemon cleanly before replacing
  binaries, and MUST NOT delete user configuration or secrets.
- Logs MAY contain bounded diagnostic output but SHOULD NOT record routine
  status polling, complete authentication exchanges, credentials, TOTP values,
  or unbounded child output.
- The implementation SHOULD NOT add application-specific proxy settings or
  force all ordinary internet traffic through the University VPN.

## Verification

Each lifecycle change MUST pass a build plus targeted tests for concurrent
connect, disconnect-during-connect, unexpected exit/reconnect, and explicit
disconnect. A live acceptance check MUST verify DNS, the selected route, TCP
445, and Finder access to the research share while connected.
