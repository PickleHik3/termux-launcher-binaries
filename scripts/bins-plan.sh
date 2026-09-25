#!/usr/bin/env bash
# The build matrix for .github/workflows/build.yml: which (tool, edition) pairs to build for a
# comma list of tools, and which release asset each produces.
#
#   scripts/bins-plan.sh all
#   scripts/bins-plan.sh dawn,btop
#   scripts/bins-plan.sh --list          the tools this knows, one per line
#
# Prints one JSON object, {"include":[{"tool":…,"edition":…,"asset":…},…]}, the shape a
# workflow's strategy.matrix takes. A tool built once per launcher edition (its binary carries
# the edition's prefix — recipes/cross/README.md) gets one entry per edition and the asset name
# recipes/cross/build-asset.sh gives that build: <tool>-aarch64 for com.termux,
# <tool>-<package>-aarch64 for any other. musl-runtime is the pair of GCC libraries
# fetch-musl-runtime.sh takes out of Alpine, published as two assets from one job.
set -euo pipefail

# tool  editions (- = one build for every edition)  assets (space separated, for -)
TOOLS='
btop         -                     btop-aarch64
tl-priv      -                     tl-priv-aarch64
kitten       -                     kitten-aarch64
sigye        -                     sigye-aarch64
fastfetch    com.termux,io.vaj.tl  -
dawn         com.termux,io.vaj.tl  -
musl-loader  com.termux,io.vaj.tl  -
musl-runtime -                     musl-libgcc-aarch64,musl-libstdcxx-aarch64
'

known() { printf '%s\n' "$TOOLS" | awk 'NF { print $1 }'; }

if [ "${1:-}" = "--list" ]; then
    known
    exit 0
fi

want="${1:-}"
[ -n "$want" ] || { echo "usage: scripts/bins-plan.sh all|<tool>[,<tool>…]" >&2; exit 2; }
if [ "$want" = all ]; then
    want="$(known | paste -sd, -)"
fi

first=1
printf '{"include":['
IFS=, read -ra asked <<<"$want"
for tool in "${asked[@]}"; do
    tool="${tool// /}"
    [ -n "$tool" ] || continue
    line="$(printf '%s\n' "$TOOLS" | awk -v t="$tool" '$1 == t')"
    if [ -z "$line" ]; then
        echo "bins-plan: unknown tool $tool (one of: $(known | paste -sd' ' -))" >&2
        exit 2
    fi
    read -r _ editions assets <<<"$line"
    if [ "$editions" = "-" ]; then
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"tool":"%s","edition":"-","asset":"%s"}' "$tool" "$assets"
        continue
    fi
    IFS=, read -ra eds <<<"$editions"
    for ed in "${eds[@]}"; do
        case "$ed" in
            com.termux) asset="$tool-aarch64" ;;
            *) asset="$tool-$ed-aarch64" ;;
        esac
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"tool":"%s","edition":"%s","asset":"%s"}' "$tool" "$ed" "$asset"
    done
done
printf ']}\n'
