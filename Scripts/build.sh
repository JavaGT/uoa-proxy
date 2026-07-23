#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="UoA Proxy"
APP_EXEC="UoAProxy"
BUILD_DIR="$ROOT/.build"
DIST="$ROOT/dist"
APP_DIR="$DIST/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "→ Building all products (release)…"
# Build the whole package so library + all executables are produced.
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
for name in uoa-proxyd uoa-proxy uoa-proxy-helper uoa-proxy-supervisor UoAProxy; do
  if [[ ! -x "$BIN_DIR/$name" ]]; then
    echo "error: missing $BIN_DIR/$name" >&2
    exit 1
  fi
done

echo "→ Staging dist/…"
rm -rf "$DIST"
mkdir -p "$DIST/bin" "$MACOS_DIR" "$CONTENTS/Resources"
cp "$BIN_DIR/uoa-proxyd" "$DIST/bin/"
cp "$BIN_DIR/uoa-proxy" "$DIST/bin/"
cp "$BIN_DIR/uoa-proxy-helper" "$DIST/bin/"
cp "$BIN_DIR/uoa-proxy-supervisor" "$DIST/bin/"
cp "$BIN_DIR/$APP_EXEC" "$MACOS_DIR/$APP_EXEC"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

OPENCONNECT_BIN="$(command -v openconnect || true)"
if [[ -z "$OPENCONNECT_BIN" ]]; then
  echo "error: openconnect is required to build the bundled runtime" >&2
  exit 1
fi
"$ROOT/Scripts/bundle-openconnect.sh" "$OPENCONNECT_BIN" "$DIST/openconnect"
cp -R "$DIST/openconnect" "$CONTENTS/Resources/openconnect"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
fi
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "→ Built:"
echo "  $DIST/bin/uoa-proxyd"
echo "  $DIST/bin/uoa-proxy"
echo "  $DIST/bin/uoa-proxy-helper"
echo "  $DIST/bin/uoa-proxy-supervisor"
echo "  $APP_DIR"
echo "  Install: ./Scripts/install.sh"
