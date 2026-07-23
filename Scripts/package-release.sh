#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0.0}"
ARCH="$(uname -m)"
EXPECTED_ARCH="${2:-$ARCH}"
OUT="$ROOT/release"
STAGE="$OUT/uoa-proxy-${VERSION}-${ARCH}"

cd "$ROOT"
"$ROOT/Scripts/build.sh"

if [[ "$ARCH" != "$EXPECTED_ARCH" ]]; then
  echo "error: runner architecture $ARCH does not match expected $EXPECTED_ARCH" >&2
  exit 1
fi
while IFS= read -r file; do
  slices="$(lipo -archs "$file")"
  if [[ " $slices " != *" $EXPECTED_ARCH "* ]]; then
    echo "error: $file is $slices, expected $EXPECTED_ARCH" >&2
    exit 1
  fi
done < <(find "$ROOT/dist/bin" "$ROOT/dist/openconnect/bin" "$ROOT/dist/openconnect/lib" \
  "$ROOT/dist/UoA Proxy.app/Contents/MacOS" -type f \( -perm -111 -o -name '*.dylib' \))

rm -rf "$STAGE"
mkdir -p "$STAGE/Applications" "$STAGE/bin" "$STAGE/share/uoa-proxy"
cp -R "$ROOT/dist/UoA Proxy.app" "$STAGE/Applications/"
cp "$ROOT/dist/bin/"* "$STAGE/bin/"
cp -R "$ROOT/dist/openconnect" "$STAGE/share/uoa-proxy/"

ARCHIVE="$OUT/uoa-proxy-${VERSION}-${ARCH}.tar.gz"
tar -C "$OUT" -czf "$ARCHIVE" "uoa-proxy-${VERSION}-${ARCH}"
(cd "$OUT" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
echo "Created $ARCHIVE"
