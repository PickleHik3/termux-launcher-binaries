#!/usr/bin/env bash
# Writes the digests of dist/tlstore-ui-<abi> into dist/tlstore, so the signed script names
# the store program built beside it and a phone's self-update can check the tlstore-ui it
# downloads against a digest the signature covers (engine/tlstore, self_update).
#
#   scripts/embed-ui-digests.sh [--check] [dist dir]
#
# The engine source carries two placeholder lines, exactly
#   TLSTORE_UI_SHA256_arm64_v8a=
#   TLSTORE_UI_SHA256_x86_64=
# and this fills in the value of each from the matching dist/tlstore-ui-<abi>. It runs inside
# scripts/release.sh --prepare, after the UI freshness check and before signing; --check only
# verifies that the lines already in dist/tlstore match the binaries (the second release.sh
# pass runs that, so a script signed against other UI bytes is refused).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

check=0
if [ "${1:-}" = "--check" ]; then
    check=1
    shift
fi
dist="${1:-$repo/dist}"
script="$dist/tlstore"

[ -f "$script" ] || { echo "embed-ui-digests: no $script" >&2; exit 1; }

fail=0
for abi in arm64-v8a x86_64; do
    bin="$dist/tlstore-ui-$abi"
    key="TLSTORE_UI_SHA256_$(printf '%s' "$abi" | tr '-' '_')"
    [ -f "$bin" ] || { echo "embed-ui-digests: missing $bin" >&2; exit 1; }
    want="$(sha256sum "$bin" | cut -d' ' -f1)"
    if ! grep -q "^$key=" "$script"; then
        echo "embed-ui-digests: $script has no $key= line" >&2
        exit 1
    fi
    have="$(sed -n "s/^$key=//p" "$script" | head -1)"
    if [ "$check" = 1 ]; then
        if [ "$have" != "$want" ]; then
            echo "embed-ui-digests: $script names $key=${have:-<empty>}, but $bin is $want" >&2
            fail=1
        fi
        continue
    fi
    tmp="$(mktemp)"
    sed "s/^$key=.*$/$key=$want/" "$script" > "$tmp"
    chmod --reference="$script" "$tmp" 2>/dev/null || chmod 755 "$tmp"
    mv "$tmp" "$script"
    echo "embed-ui-digests: $key=$want"
done

if [ "$check" = 1 ]; then
    [ "$fail" = 0 ] || exit 1
    echo "embed-ui-digests: $script names the tlstore-ui binaries in $dist"
fi
exit 0
