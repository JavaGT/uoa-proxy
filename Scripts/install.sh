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

# Stop the old daemon before replacing any executable it may be running. A
# failed graceful stop is fatal; installing a mixed-version runtime is unsafe.
if [[ -S "$HOME/Library/Application Support/UoAProxy/control.sock" ]]; then
  stopped=false
  for existing_cli in "$BIN_DIR/uoa-proxy" /opt/homebrew/bin/uoa-proxy /usr/local/bin/uoa-proxy "$HOME/.local/bin/uoa-proxy"; do
    if [[ -x "$existing_cli" ]] && "$existing_cli" daemon stop; then
      stopped=true
      break
    fi
  done
  $stopped || { echo "error: existing daemon did not stop cleanly" >&2; exit 1; }
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
# The bundled libraries are read-only, so copying over an existing runtime
# fails. Stage a complete replacement, preserving the previous copy for recovery.
runtime_stage="$(mktemp -d "$SHARE_DIR/.runtime.XXXXXX")"
cp -R "$DIST/openconnect" "$runtime_stage/openconnect"
if [[ -e "$SHARE_DIR/openconnect" ]]; then
  mv "$SHARE_DIR/openconnect" "$runtime_stage/previous"
fi
if ! mv "$runtime_stage/openconnect" "$SHARE_DIR/openconnect"; then
  if [[ -e "$runtime_stage/previous" ]]; then
    mv "$runtime_stage/previous" "$SHARE_DIR/openconnect"
  fi
  echo "error: could not install the bundled runtime" >&2
  exit 1
fi

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
  launchctl bootstrap "gui/${uid}" "$LAUNCH_AGENT_PLIST"
  launchctl kickstart "gui/${uid}/${LAUNCH_AGENT_LABEL}"
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
  "$BIN_DIR/uoa-proxy" daemon status
else
  echo "warning: control socket not found yet at $SOCK" >&2
  echo "  Try: $BIN_DIR/uoa-proxy daemon start" >&2
  exit 1
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
