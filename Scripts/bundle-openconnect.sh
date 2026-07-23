#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-}"
DEST="${2:-}"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -x "$SOURCE" || -z "$DEST" ]]; then
  echo "usage: $0 /path/to/openconnect destination" >&2
  exit 64
fi

mkdir -p "$DEST/bin" "$DEST/lib"
cp "$SOURCE" "$DEST/bin/openconnect"

declare -a queue=("$SOURCE")
# Bash 3.2 treats an empty array as unset under `set -u`; retain a sentinel.
declare -a seen=("")
while ((${#queue[@]})); do
  current="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r dependency; do
    [[ "$dependency" == /System/* || "$dependency" == /usr/lib/* ]] && continue
    [[ "$dependency" == @* ]] && continue
    [[ -f "$dependency" ]] || {
      echo "error: unresolved openconnect dependency: $dependency" >&2
      exit 1
    }
    dependency="$(cd "$(dirname "$dependency")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$dependency")")"
    already_seen=false
    for bundled_dependency in "${seen[@]}"; do
      if [[ "$bundled_dependency" == "$dependency" ]]; then
        already_seen=true
        break
      fi
    done
    $already_seen && continue
    seen+=("$dependency")
    basename="$(basename "$dependency")"
    if [[ -e "$DEST/lib/$basename" ]]; then
      echo "error: duplicate bundled library name: $basename" >&2
      exit 1
    fi
    cp "$dependency" "$DEST/lib/$basename"
    queue+=("$dependency")
  done < <(otool -L "$current" | tail -n +2 | sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/')
done

rewrite_dependencies() {
  local file="$1"
  local prefix="$2"
  while IFS= read -r dependency; do
    [[ "$dependency" == /System/* || "$dependency" == /usr/lib/* ]] && continue
    [[ "$dependency" == @* ]] && continue
    install_name_tool -change "$dependency" "$prefix/$(basename "$dependency")" "$file"
  done < <(otool -L "$file" | tail -n +2 | sed -E 's/^[[:space:]]+([^[:space:]]+).*/\1/')
}

rewrite_dependencies "$DEST/bin/openconnect" "@executable_path/../lib"
for library in "$DEST"/lib/*.dylib; do
  [[ -e "$library" ]] || continue
  rewrite_dependencies "$library" "@loader_path"
  install_name_tool -id "@loader_path/$(basename "$library")" "$library"
  codesign --force --sign - "$library" 2>/dev/null || true
done
codesign --force --sign - "$DEST/bin/openconnect" 2>/dev/null || true

script=""
for candidate in \
  "$(dirname "$(dirname "$SOURCE")")/etc/vpnc/vpnc-script" \
  /opt/homebrew/etc/vpnc/vpnc-script \
  /usr/local/etc/vpnc/vpnc-script; do
  if [[ -f "$candidate" ]]; then script="$candidate"; break; fi
done
if [[ -z "$script" ]]; then
  echo "error: vpnc-script not found" >&2
  exit 1
fi
cp "$script" "$DEST/vpnc-script"
# The override below bypasses the generic functions. Remove their direct
# networksetup calls as defense in depth without rewriting upstream control
# flow, which varies between vpnc-script releases.
sed -i '' '/^[[:space:]]*networksetup -setdnsservers/d' "$DEST/vpnc-script"
# Override the generic Darwin resolver functions before do_connect is defined.
# The packaged implementation creates only a tunnel-scoped dynamic resolver;
# it never mutates the active physical network service.
dns_fragment="$SOURCE_DIR/vpnc-darwin-dns.sh"
awk -v fragment="$dns_fragment" '
  /^do_connect\(\) \{/ && !inserted {
    while ((getline line < fragment) > 0) print line
    close(fragment)
    inserted = 1
  }
  { print }
' "$DEST/vpnc-script" > "$DEST/vpnc-script.patched"
mv "$DEST/vpnc-script.patched" "$DEST/vpnc-script"
awk '
  { print }
  /^[[:space:]]*do_connect[[:space:]]*$/ { print "\t\techo \"uoa-proxy: tunnel ready\"" }
' "$DEST/vpnc-script" > "$DEST/vpnc-script.patched"
mv "$DEST/vpnc-script.patched" "$DEST/vpnc-script"
grep -q 'MODIFYRESOLVCONF=modify_resolvconf_uoa_darwin' "$DEST/vpnc-script"
grep -q 'uoa-proxy: tunnel ready' "$DEST/vpnc-script"
! grep -q 'networksetup -setdnsservers' "$DEST/vpnc-script"
sh -n "$DEST/vpnc-script"
chmod 755 "$DEST/bin/openconnect" "$DEST/vpnc-script"

echo "Bundled openconnect and $((${#seen[@]} - 1)) libraries in $DEST"
