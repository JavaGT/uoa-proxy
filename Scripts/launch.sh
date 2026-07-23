#!/usr/bin/env bash
# Start the daemon (if needed) and optionally the menu bar UI binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if command -v uoa-proxy >/dev/null 2>&1; then
  CLI=uoa-proxy
elif [[ -x /usr/local/bin/uoa-proxy ]]; then
  CLI=/usr/local/bin/uoa-proxy
elif [[ -x "$HOME/.local/bin/uoa-proxy" ]]; then
  CLI="$HOME/.local/bin/uoa-proxy"
elif [[ -x "$ROOT/dist/bin/uoa-proxy" ]]; then
  CLI="$ROOT/dist/bin/uoa-proxy"
else
  echo "error: uoa-proxy not found. Run ./Scripts/install.sh" >&2
  exit 1
fi

"$CLI" daemon start
"$CLI" status || true

if [[ "${1:-}" == "--ui" ]]; then
  APP="/Applications/UoA Proxy.app/Contents/MacOS/UoAProxy"
  if [[ -x "$APP" ]]; then
    nohup "$APP" >/dev/null 2>&1 &
    disown || true
    echo "Menu bar UI started (needs a graphical session to appear)."
  else
    echo "Menu bar app not installed."
  fi
fi
