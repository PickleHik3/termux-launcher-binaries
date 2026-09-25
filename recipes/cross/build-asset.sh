#!/bin/bash
# build-asset.sh — one release asset from the recipes in this directory, under the name the
# tlstore catalog installs it by.
#
#   ./build-asset.sh <tool> [edition]
#
#   tool      btop | tl-priv | kitten | sigye | fastfetch | dawn | musl-loader | musl-runtime
#   edition   com.termux (default) | io.vaj.tl — only for fastfetch, dawn and musl-loader, the
#             three whose binary carries the edition's prefix (README.md, "One build per
#             launcher edition"); the others build once for every edition
#
# Runs the tool's recipe (assembling the edition's Termux sysroot first where one is needed)
# and copies the result into $TL_ASSETS as <tool>-aarch64, or <tool>-<package>-aarch64 for an
# edition other than com.termux — the asset name a bare `binaries:<tool>@<tag>` source resolves
# to. musl-runtime yields two, musl-libgcc-aarch64 and musl-libstdcxx-aarch64.
#
# This is what .github/workflows/build.yml runs, one job per (tool, edition), and it runs the
# same way on a laptop. Env:
#   TL_NDK      the Android NDK (default $ANDROID_NDK_HOME, else $ANDROID_HOME/ndk/29.0.14206865)
#   TL_WORK     where sources, sysroots and build trees go (default $PWD); the sysroot and the
#               .deb cache for an edition are TL_WORK/sysroot-<edition> and TL_WORK/debs-<edition>,
#               so a second tool for the same edition reuses them
#   TL_ASSETS   where the finished assets land (default $TL_WORK/assets)
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
tool="${1:-}"
edition="${2:-com.termux}"
[ -n "$tool" ] || { echo "usage: build-asset.sh <tool> [edition]" >&2; exit 2; }
[ "$edition" != "-" ] || edition=com.termux

TL_WORK=${TL_WORK:-"$PWD"}
TL_ASSETS=${TL_ASSETS:-"$TL_WORK/assets"}
NDK_VERSION=29.0.14206865
if [ -z "${TL_NDK:-}" ]; then
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        TL_NDK="$ANDROID_NDK_HOME"
    else
        TL_NDK="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/$NDK_VERSION"
    fi
fi
export TL_NDK

case "$edition" in
    com.termux)
        TERMUX_REPO="https://packages.termux.dev/apt/termux-main"
        suffix=""
        ;;
    io.vaj.tl)
        TERMUX_REPO="https://repo.pathayam.xyz"
        suffix="-$edition"
        ;;
    *) echo "build-asset: unknown edition $edition (com.termux or io.vaj.tl)" >&2; exit 2 ;;
esac
TERMUX_PREFIX="/data/data/$edition/files/usr"
TERMUX_HOME="/data/data/$edition/files/home"
export TERMUX_PREFIX TERMUX_HOME

per_edition() {
    case "$tool" in
        fastfetch|dawn|musl-loader) return 0 ;;
    esac
    if [ "$edition" != com.termux ]; then
        echo "build-asset: $tool is built once for every edition; drop the edition argument" >&2
        exit 2
    fi
    return 1
}
if per_edition; then asset="$tool$suffix-aarch64"; else asset="$tool-aarch64"; fi

export TL_OUT="$TL_WORK/out-$tool-$edition"
export TL_BUILD_DIR="$TL_WORK/build-$tool-$edition"
mkdir -p "$TL_ASSETS" "$TL_OUT" "$TL_BUILD_DIR"

# sysroot <packages…> — the edition's Termux sysroot, from its own repository. Re-running it
# over a cached .deb directory extracts again without touching the network.
sysroot() {
    export TL_SYSROOT="$TL_WORK/sysroot-$edition"
    TL_CACHE="$TL_WORK/debs-$edition" TL_TERMUX_REPO="$TERMUX_REPO" \
        "$SCRIPT_DIR/termux-sysroot.sh" "$@"
}

# The NDK's clang for this API, callable as plain `clang`: build-musl-loader.sh was written for
# Termux's own clang (it names `clang` and a compiler-rt it finds under $PREFIX), and the NDK's
# wrapper scripts cannot be symlinked under another name (they locate the toolchain from $0).
ndk_clang_as_clang() {
    local api="$1" bin="$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin" wrap="$TL_BUILD_DIR/cc"
    [ -x "$bin/clang" ] || { echo "build-asset: no NDK clang at $bin (set TL_NDK)" >&2; exit 1; }
    mkdir -p "$wrap"
    printf '#!/bin/sh\nexec "%s/clang" --target=aarch64-linux-android%s "$@"\n' "$bin" "$api" > "$wrap/clang"
    chmod 755 "$wrap/clang"
    PATH="$wrap:$PATH"
    export PATH
    LIBCC=$(find "$TL_NDK/toolchains/llvm/prebuilt/linux-x86_64/lib/clang" \
        \( -name 'libclang_rt.builtins-aarch64-android.a' -o -path '*/aarch64/libclang_rt.builtins-android.a' \) \
        2>/dev/null | head -1)
    [ -n "$LIBCC" ] || { echo "build-asset: no compiler-rt builtins for aarch64 in the NDK" >&2; exit 1; }
    export LIBCC
}

echo "== $tool for $edition -> $asset"
case "$tool" in
    btop)
        "$SCRIPT_DIR/build-btop.sh"
        cp "$TL_OUT/btop" "$TL_ASSETS/$asset"
        ;;
    tl-priv)
        "$SCRIPT_DIR/build-tl-priv.sh"
        cp "$TL_OUT/tl-priv" "$TL_ASSETS/$asset"
        ;;
    kitten)
        "$SCRIPT_DIR/build-kitten.sh"
        cp "$TL_OUT/kitten-android-arm64" "$TL_ASSETS/$asset"
        ;;
    sigye)
        "$SCRIPT_DIR/build-sigye.sh"
        cp "$TL_OUT/sigye" "$TL_ASSETS/$asset"
        ;;
    fastfetch)
        sysroot
        "$SCRIPT_DIR/build-fastfetch.sh"
        cp "$TL_OUT/fastfetch" "$TL_ASSETS/$asset"
        ;;
    dawn)
        sysroot libcurl openssl zlib libnghttp2
        "$SCRIPT_DIR/build-dawn.sh"
        cp "$TL_OUT/dawn" "$TL_ASSETS/$asset"
        ;;
    musl-loader)
        ndk_clang_as_clang 26
        # Its shebang is Termux's sh; the script itself is POSIX.
        sh "$SCRIPT_DIR/build-musl-loader.sh"
        cp "$TL_OUT/$asset" "$TL_ASSETS/$asset"
        ;;
    musl-runtime)
        "$SCRIPT_DIR/fetch-musl-runtime.sh"
        cp "$TL_OUT/musl-libgcc" "$TL_ASSETS/musl-libgcc-aarch64"
        cp "$TL_OUT/musl-libstdcxx" "$TL_ASSETS/musl-libstdcxx-aarch64"
        ;;
    *)
        echo "build-asset: unknown tool $tool" >&2
        exit 2
        ;;
esac

echo
for f in "$TL_ASSETS"/*-aarch64; do
    [ -f "$f" ] || continue
    printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
