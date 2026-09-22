#!/bin/bash
# fetch-musl-runtime.sh — take musl's libstdc++ and libgcc_s out of Alpine's aarch64 packages.
#
# Some prebuilt binaries from the wider Linux world need more of the musl world than its libc:
# opencode, for one, links libstdc++ and libgcc_s. Termux ships neither in a musl flavour — its C++
# library is the NDK's, linked against Bionic — so the musl loader cannot use them and the two have
# to come from somewhere that builds against musl. Alpine is that somewhere, and its packages are
# plain .tar.gz files with a signature glued on the front.
#
# These are not built here: they are GCC's runtime libraries, redistributed unchanged under the GPL
# with the GCC Runtime Library Exception. `apk fetch` is not needed and neither is an Alpine host.
set -euo pipefail

ALPINE_BRANCH=${ALPINE_BRANCH:-v3.22}
ALPINE_MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
GCC_VERSION=14.2.0-r6
LIBGCC_SHA256=ba1835eec3ad8a120efd3d5020e561d53553a0513763a08f509e3ce6d4baa9ca
LIBSTDCXX_SHA256=0d2f054057a4f932e985a129eccb79908b40964185139a0a609aed3032aba064

TL_OUT=${TL_OUT:-"$PWD/out"}
TL_BUILD_DIR=${TL_BUILD_DIR:-"$PWD/build-musl-runtime"}

mkdir -p "$TL_OUT" "$TL_BUILD_DIR"
cd "$TL_BUILD_DIR"

fetch() {
    local package="$1" want="$2" file="$1-$GCC_VERSION.apk"
    [ -f "$file" ] || curl -fsSLO "$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/$file"
    echo "$want  $file" | sha256sum -c - >/dev/null
    # An .apk is a gzip stream per section concatenated; tar reads the whole thing and the
    # signature section simply unpacks as a dotfile nobody looks at.
    tar xzf "$file" 2>/dev/null || true
}

fetch libgcc "$LIBGCC_SHA256"
fetch libstdc++ "$LIBSTDCXX_SHA256"

[ -f usr/lib/libgcc_s.so.1 ] || { echo "error: libgcc_s.so.1 was not in the package" >&2; exit 1; }
[ -f usr/lib/libstdc++.so.6 ] || { echo "error: libstdc++.so.6 was not in the package" >&2; exit 1; }

# Copy through the symlink: the store installs one file per item, not a link farm.
cp -L usr/lib/libgcc_s.so.1 "$TL_OUT/musl-libgcc"
cp -L usr/lib/libstdc++.so.6 "$TL_OUT/musl-libstdcxx"
chmod 644 "$TL_OUT/musl-libgcc" "$TL_OUT/musl-libstdcxx"

# A build for the wrong libc is the one mistake that would not show until a phone refused to start
# the tool, so check the soname and the libc these were linked against.
for pair in "musl-libgcc:libgcc_s.so.1" "musl-libstdcxx:libstdc++.so.6"; do
    file="$TL_OUT/${pair%%:*}"
    soname="${pair##*:}"
    if ! grep -qa "$soname" "$file"; then
        echo "error: $file does not carry the soname $soname" >&2
        exit 1
    fi
    if ! grep -qa "libc.musl-aarch64.so.1" "$file"; then
        echo "error: $file is not linked against musl" >&2
        exit 1
    fi
done

echo
echo "Built: $TL_OUT/musl-libgcc, $TL_OUT/musl-libstdcxx"
ls -l "$TL_OUT/musl-libgcc" "$TL_OUT/musl-libstdcxx"
