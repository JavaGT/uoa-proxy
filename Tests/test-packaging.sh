#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$ROOT/Scripts/bundle-openconnect.sh" "$(command -v openconnect)" "$TMP/openconnect" >/dev/null
script="$TMP/openconnect/vpnc-script"

sh -n "$script"
grep -q 'MODIFYRESOLVCONF=modify_resolvconf_uoa_darwin' "$script"
grep -q 'RESTORERESOLVCONF=restore_resolvconf_uoa_darwin' "$script"
grep -q 'set State:/Network/Service/\$TUNDEV/DNS' "$script"
grep -q 'remove State:/Network/Service/\$TUNDEV/DNS' "$script"
grep -q 'uoa-proxy: tunnel ready' "$script"
! grep -q 'networksetup -setdnsservers' "$script"
grep -q "tr ',' ' '" "$script"

# EOF on the daemon-owned control channel must terminate and reap the exact
# supervised child promptly. The helper refuses this test mode when run as root.
helper="$(cd "$ROOT" && swift build -c release --show-bin-path)/uoa-proxy-helper"
supervisor="${helper%/*}/uoa-proxy-supervisor"
swift "$ROOT/Tests/supervisor-launch.swift" "$supervisor"
started="$(date +%s)"
set +e
"$helper" self-test-supervision </dev/null
status="$?"
set -e
[[ "$status" -eq 143 ]]
elapsed="$(( $(date +%s) - started ))"
[[ "$elapsed" -lt 5 ]]

# Released checksum manifests must be portable after downloading both files.
archive="$TMP/archive.tar.gz"
printf 'release payload' > "$archive"
(cd "$TMP" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
! grep -q "$TMP" "$archive.sha256"
(cd "$TMP" && shasum -a 256 -c "$(basename "$archive").sha256")
