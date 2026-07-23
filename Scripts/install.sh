#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="UoA Proxy"
DIST="$ROOT/dist"
APP_SRC="$DIST/${APP_NAME}.app"
APP_DST="/Applications/${APP_NAME}.app"

# Prefer /usr/local/bin when writable, else ~/.local/bin
if [[ -w /usr/local/bin ]] || mkdir -p /usr/local/bin 2>/dev/null && [[ -w /usr/local/bin ]]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

LAUNCH_AGENT_LABEL="nz.ac.auckland.uoa-proxy.daemon"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

if [[ ! -x "$DIST/bin/uoa-proxyd" || ! -x "$DIST/bin/uoa-proxy" \
   || ! -x "$DIST/bin/uoa-proxy-helper" || ! -x "$DIST/bin/uoa-proxy-supervisor" \
   || ! -x "$DIST/openconnect/bin/openconnect" || ! -d "$APP_SRC" ]]; then
  echo "Artifacts missing — building…"
  "$ROOT/Scripts/build.sh"
fi

echo "→ Installing CLI + daemon to $BIN_DIR"
cp "$DIST/bin/uoa-proxyd" "$BIN_DIR/uoa-proxyd"
cp "$DIST/bin/uoa-proxy" "$BIN_DIR/uoa-proxy"
cp "$DIST/bin/uoa-proxy-helper" "$BIN_DIR/uoa-proxy-helper"
cp "$DIST/bin/uoa-proxy-supervisor" "$BIN_DIR/uoa-proxy-supervisor"
chmod 755 "$BIN_DIR/uoa-proxyd" "$BIN_DIR/uoa-proxy" \
  "$BIN_DIR/uoa-proxy-helper" "$BIN_DIR/uoa-proxy-supervisor"

SHARE_DIR="${BIN_DIR%/bin}/share/uoa-proxy"
mkdir -p "$SHARE_DIR"
cp -R "$DIST/openconnect" "$SHARE_DIR/"

echo "→ Installing menu bar app to $APP_DST"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
xattr -cr "$APP_DST" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DST" 2>/dev/null || true

echo "→ Installing LaunchAgent $LAUNCH_AGENT_LABEL"
mkdir -p "$(dirname "$LAUNCH_AGENT_PLIST")"
cat > "$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCH_AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${BIN_DIR}/uoa-proxyd</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>StandardOutPath</key>
	<string>${HOME}/Library/Application Support/UoAProxy/daemon.launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>${HOME}/Library/Application Support/UoAProxy/daemon.launchd.err.log</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
EOF

# Ensure support dir exists for logs
mkdir -p "$HOME/Library/Application Support/UoAProxy"

# Start daemon: LaunchAgent if Aqua available, else daemonize (SSH-friendly)
manager="$(launchctl managername 2>/dev/null || true)"
if [[ "$manager" == "Aqua" ]]; then
  echo "→ Starting LaunchAgent (Aqua session)…"
  uid="$(id -u)"
  launchctl bootout "gui/${uid}/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/${uid}" "$LAUNCH_AGENT_PLIST" 2>/dev/null \
    || launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null \
    || true
  launchctl kickstart -k "gui/${uid}/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
else
  echo "→ Non-Aqua session (SSH?) — starting uoa-proxyd --daemonize"
  "$BIN_DIR/uoa-proxy" daemon stop 2>/dev/null || true
  "$BIN_DIR/uoa-proxyd" --daemonize
fi

# Wait for socket
SOCK="$HOME/Library/Application Support/UoAProxy/control.sock"
for _ in $(seq 1 30); do
  if [[ -S "$SOCK" ]]; then
    break
  fi
  sleep 0.1
done

if [[ -S "$SOCK" ]]; then
  echo "→ Daemon is up ($SOCK)"
  "$BIN_DIR/uoa-proxy" daemon status || true
else
  echo "warning: control socket not found yet at $SOCK" >&2
  echo "  Try: $BIN_DIR/uoa-proxy daemon start" >&2
fi

# PATH hint
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo ""
  echo "Note: add $BIN_DIR to your PATH, e.g.:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

cat <<EOF

Installed:
  $BIN_DIR/uoa-proxyd     always-on VPN control daemon
  $BIN_DIR/uoa-proxy      CLI (works over SSH)
  $APP_DST                menu bar UI (optional; needs desktop)

Quick start (SSH-friendly):
  uoa-proxy install-sudo              # once — install fixed privileged runner
  uoa-proxy config set user jgra818
  uoa-proxy config set password       # prompts
  uoa-proxy config set totp           # Base32 secret from QR
  uoa-proxy connect
  uoa-proxy status
  uoa-proxy disconnect

Menu bar app (on the Mac desktop):
  uoa-proxy ui
  # or: open "$APP_DST"
  (Quit UI does not stop the daemon)

EOF
