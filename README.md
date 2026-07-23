# UoA Proxy

Always-on VPN control for the University of Auckland Fortinet gateway (`openconnect`), with:

1. **`uoa-proxyd`** — background daemon that owns the connection  
2. **`uoa-proxy`** — CLI (works over **SSH**)  
3. **UoA Proxy.app** — optional menu bar UI that talks to the same daemon  

```
┌─────────────┐   ┌──────────────────┐
│ uoa-proxy   │──▶│                  │      sudo openconnect
│ (CLI / SSH) │   │   uoa-proxyd     │── fixed helper ─────▶  VPN
│ UoA Proxy   │──▶│   control.sock   │
│ (menu bar)  │   │                  │
└─────────────┘   └──────────────────┘
```

## Install

```bash
./Scripts/build.sh
./Scripts/install.sh
```

### Homebrew

After replacing `YOUR_GITHUB_USER` in `Formula/uoa-proxy.rb` with the GitHub
account that owns this repository, put that formula in a tap repository (for
example `YOUR_GITHUB_USER/homebrew-tap`) and install it with:

```bash
brew install YOUR_GITHUB_USER/tap/uoa-proxy
brew services start uoa-proxy
uoa-proxy install-sudo   # once per Mac; asks for the Mac administrator password
```

The formula builds the tagged source with Homebrew's `openconnect` and `vpnc`
dependencies. The menu bar app is installed under the Homebrew prefix and can
be opened with `uoa-proxy ui`.

Tagged GitHub releases also publish architecture-specific archives for direct
download (`arm64` and `x86_64`). Create one with `git tag v1.0.0 && git push
origin v1.0.0`.

Puts:

| Component | Location |
|-----------|----------|
| Daemon | `/usr/local/bin/uoa-proxyd` (or `~/.local/bin`) |
| CLI | `/usr/local/bin/uoa-proxy` |
| Process supervisor | `/usr/local/bin/uoa-proxy-supervisor` |
| Menu bar app | `/Applications/UoA Proxy.app` |
| LaunchAgent | `~/Library/LaunchAgents/nz.ac.auckland.uoa-proxy.daemon.plist` |
| Bundled runtime | `/usr/local/share/uoa-proxy/openconnect` |
| Root-owned runtime | `/Library/PrivilegedHelperTools/nz.ac.auckland.uoa-proxy` |

Over SSH the installer starts the daemon with `uoa-proxyd --daemonize` (LaunchAgents need a GUI login session).

## First-time setup (SSH-friendly)

Just connect — missing pieces are prompted interactively:

```bash
uoa-proxy              # welcome + prompts if not configured, then status
uoa-proxy connect      # same prompts, then connect
# or explicitly:
uoa-proxy setup
```

You will be asked (only for what is missing) for:

1. University username  
2. VPN password (hidden)  
3. TOTP Base32 secret from your authenticator QR (hidden)  
4. The fixed privileged VPN helper (Mac password, hidden) — required over SSH  

```bash
uoa-proxy status
uoa-proxy disconnect
```

### TOTP secret from a QR code

```
otpauth://totp/UoA:jgra818?secret=JBSWY3DPEHPK3PXP&issuer=UoA
```

Use only the `secret=` value (`JBSWY3DPEHPK3PXP`).

## CLI

```text
uoa-proxy                         # setup if needed + status
uoa-proxy setup [--force]
uoa-proxy connect | disconnect | toggle
uoa-proxy status | otp
uoa-proxy check-smb
uoa-proxy config
uoa-proxy config set user|password|totp …
uoa-proxy daemon status|start|stop|restart
uoa-proxy ui                          # open menu bar app (desktop)
uoa-proxy install-sudo
uoa-proxy logs [daemon|vpn]
```

## Menu bar app

Optional — VPN is fully usable from the CLI. On a **desktop** (Aqua) session:

```bash
uoa-proxy ui
# same as:
open "/Applications/UoA Proxy.app"
```

The **daemon does not launch the UI** (it is headless and often started over SSH).  
`uoa-proxy ui` starts the daemon if needed, then opens the app.

**Quit UI** only exits the menu bar process. The daemon keeps the VPN up.  
Connect / disconnect / settings all go through the daemon — same as the CLI.

`open` / `uoa-proxy ui` fail over plain SSH (`OSLaunchdErrorDomain Code=125`); use Screen Sharing or a local Terminal for the menu bar, and `uoa-proxy` for VPN control.

## How connect works

The daemon starts one foreground OpenConnect process and owns that exact process group until disconnect or shutdown. It does not use PID files, `pgrep`, `pkill`, or process-name adoption. Unexpected exits reconnect with bounded exponential backoff; OpenConnect also handles short transport interruptions itself.

The app packages OpenConnect, its non-system libraries, and `vpnc-script`. A validating root-owned helper permits only the Fortinet protocol, the University gateway, the configured username, and the packaged routing script. Password and TOTP are supplied over standard input and are redacted from logs. The sudoers rule grants only this helper—not arbitrary OpenConnect arguments or kill commands.

This remains a kernel split-tunnel VPN: the gateway-provided University routes and DNS are installed on a `utun` interface, while unrelated traffic keeps its normal route.

## Research drive (SMB)

After `uoa-proxy connect`, check the route and SMB port:

```bash
uoa-proxy check-smb
# equivalent manual checks:
dscacheutil -q host -a name files.auckland.ac.nz
route -n get files.auckland.ac.nz | grep interface
nc -G 5 -vz files.auckland.ac.nz 445
```

The route should use a `utun` interface and TCP port 445 should connect. Then use Finder’s **Go → Connect to Server** with:

```text
smb://files.auckland.ac.nz/research/resart202600017-studentworkandwellbeing
```

If DNS resolves or port 445 works only off the VPN route, capture `uoa-proxy logs vpn`; the University gateway may not have supplied the required file-server subnet route for the account/session.

## Paths

| Path | Purpose |
|------|---------|
| `~/Library/Application Support/UoAProxy/control.sock` | Daemon IPC |
| `~/Library/Application Support/UoAProxy/config.json` | Non-secret settings |
| `~/Library/Application Support/UoAProxy/openconnect.log` | Bounded, owner-only VPN log |
| `~/Library/Application Support/UoAProxy/daemon.log` | Daemon log |
| `~/Library/Application Support/UoAProxy/secrets.json` | Password + TOTP secret (mode 0600; not Keychain — Keychain blocks SSH/daemon access) |

## Uninstall

```bash
uoa-proxy disconnect 2>/dev/null || true
uoa-proxy daemon stop 2>/dev/null || true
rm -f ~/Library/LaunchAgents/nz.ac.auckland.uoa-proxy.daemon.plist
rm -f /usr/local/bin/uoa-proxy /usr/local/bin/uoa-proxyd /usr/local/bin/uoa-proxy-supervisor /usr/local/bin/uoa-proxy-helper
rm -f ~/.local/bin/uoa-proxy ~/.local/bin/uoa-proxyd ~/.local/bin/uoa-proxy-supervisor ~/.local/bin/uoa-proxy-helper
rm -rf "/Applications/UoA Proxy.app"
rm -rf ~/Library/Application\ Support/UoAProxy
sudo rm -f /etc/sudoers.d/uoa-proxy
sudo rm -rf /Library/PrivilegedHelperTools/nz.ac.auckland.uoa-proxy
```
