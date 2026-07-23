#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
ARCH="$(uname -m)"
OUT="$ROOT/release"
STAGE="$OUT/uoa-proxy-${VERSION}-${ARCH}"

cd "$ROOT"
"$ROOT/Scripts/build.sh"

rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/bin" "$STAGE/share/uoa-proxy"
cp -R "$ROOT/dist/UoA Proxy.app" "$STAGE/Applications/"
cp "$ROOT/dist/bin/"* "$STAGE/bin/"
cp -R "$ROOT/dist/openconnect" "$STAGE/share/uoa-proxy/"

ARCHIVE="$OUT/uoa-proxy-${VERSION}-${ARCH}.tar.gz"
tar -C "$OUT" -czf "$ARCHIVE" "uoa-proxy-${VERSION}-${ARCH}"
echo "Created $ARCHIVE"
