#!/usr/bin/env bash
# Checks dist/tlstore-ui-<abi> against the working tree's ui/ sources — the same check the
# launcher's own app/build.gradle checkTlstoreUiFresh task ran before the store moved into this
# repository.
#
#   scripts/check-dist.sh
#
# Fails when a dist/tlstore-ui-<abi> binary is missing, or its baked-in TLSTORE_UI_SRC_HASH
# (see ui/build.rs, scripts/ui-src-hash.sh) does not match a fresh hash of ui/src, ui/Cargo.toml
# and ui/Cargo.lock — the sign that scripts/build-ui.sh --install was not run after a source
# change. Never executes the binary (it may be built for a different processor than this host);
# greps its bytes for the literal marker line `--version` prints instead.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
dist="$repo/dist"

want="$("$here/ui-src-hash.sh")"
fail=0

for abi in arm64-v8a x86_64; do
    bin="$dist/tlstore-ui-$abi"
    if [ ! -f "$bin" ]; then
        echo "check-dist: missing $bin — run scripts/build-ui.sh --install" >&2
        fail=1
        continue
    fi
    got="$(grep -a -o "TLSTORE_UI_SRC_HASH=[0-9a-f]*" "$bin" | head -1 | cut -d= -f2)"
    if [ -z "$got" ]; then
        echo "check-dist: $bin has no TLSTORE_UI_SRC_HASH baked in" >&2
        fail=1
    elif [ "$got" != "$want" ]; then
        echo "check-dist: $bin was built from different ui/ sources (baked $got, working tree $want) — run scripts/build-ui.sh --install" >&2
        fail=1
    fi
done

[ "$fail" != 0 ] || echo "check-dist: dist/tlstore-ui-<abi> matches the working tree ($want)"
exit "$fail"
