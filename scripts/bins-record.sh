#!/usr/bin/env bash
# Records a bins-… release in the catalog's inputs: the SHA256SUMS lines of the assets it
# published, and the items.tsv rows that point at them, moved to its tag.
#
#   scripts/bins-record.sh <tag> <assets dir>
#
# <assets dir> holds the files a build published, under their asset names (<tool>-aarch64,
# <tool>-<package>-aarch64). For each one:
#   - its line in SHA256SUMS is replaced (or added), every other line left as it is;
#   - every items.tsv row whose source is the bare form `binaries:<asset>@<old tag>` for it
#     moves to `binaries:<asset>@<tag>`. Rows for assets the build did not produce keep their
#     tag and digest.
# Phones decide whether an installed item has an update by its version alone (engine/tlstore,
# update_items and snapshot_rows compare the catalog's version with the installed one), so a
# rebuilt binary at an unchanged version would never be offered. A row whose digest changed and
# whose version ends in `+<something>.<N>` — dawn's `0.1.3+0e958747.3`, upstream version plus
# the commit plus a build number — gets N bumped here; any other version is left alone and
# named on stderr, for the maintainer to bump by hand (docs/maintainer/catalog.md, "Rebuilding
# a binary"). Prints one line per change on stdout, for the workflow's run summary.
#
# .github/workflows/build.yml runs this after creating the release, then commits the result.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
sums="$repo/SHA256SUMS"
items="$here/items.tsv"

tag="${1:-}"
dir="${2:-}"
[ -n "$tag" ] && [ -n "$dir" ] || { echo "usage: scripts/bins-record.sh <tag> <assets dir>" >&2; exit 2; }
[ -d "$dir" ] || { echo "bins-record: no directory $dir" >&2; exit 1; }
[ -f "$items" ] || { echo "bins-record: no $items" >&2; exit 1; }
[ -f "$sums" ] || : > "$sums"

# --- the assets: name, new digest, old digest --------------------------------
declare -A new_digest=() old_digest=()
while read -r digest name; do
    [ -n "${name:-}" ] || continue
    old_digest["$name"]="$digest"
done < "$sums"

count=0
for f in "$dir"/*-aarch64; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    new_digest["$name"]="$(sha256sum "$f" | cut -d' ' -f1)"
    count=$((count + 1))
done
[ "$count" -gt 0 ] || { echo "bins-record: nothing named *-aarch64 in $dir" >&2; exit 1; }

rebuilt=""
changed=""
for name in "${!new_digest[@]}"; do
    rebuilt="$rebuilt $name"
    if [ "${old_digest[$name]:-}" != "${new_digest[$name]}" ]; then
        changed="$changed $name"
        if [ -n "${old_digest[$name]:-}" ]; then
            echo "$name: digest ${old_digest[$name]:0:12}… -> ${new_digest[$name]:0:12}…"
        else
            echo "$name: new, digest ${new_digest[$name]:0:12}…"
        fi
    else
        echo "$name: digest unchanged"
    fi
done

# --- SHA256SUMS: replace in place, append what is new ------------------------
tmp="$(mktemp)"
declare -A written=()
while IFS= read -r line || [ -n "$line" ]; do
    name="${line##*  }"
    if [ -n "$name" ] && [ -n "${new_digest[$name]:-}" ]; then
        printf '%s  %s\n' "${new_digest[$name]}" "$name" >> "$tmp"
        written["$name"]=1
    else
        printf '%s\n' "$line" >> "$tmp"
    fi
done < "$sums"
for name in $(printf '%s\n' "${!new_digest[@]}" | LC_ALL=C sort); do
    [ -n "${written[$name]:-}" ] || printf '%s  %s\n' "${new_digest[$name]}" "$name" >> "$tmp"
done
mv "$tmp" "$sums"

# --- items.tsv: move the rows to the tag, bump a +…​.N version whose digest moved ------------
tmp="$(mktemp)"
awk -F '\t' -v OFS='\t' -v tag="$tag" -v rebuilt=" $rebuilt " -v changed=" $changed " '
    /^#/ || NF < 5 { print; next }
    {
        src = $5
        if (index(src, "binaries:") != 1) { print; next }
        rest = substr(src, 10)
        asset = rest; sub(/@[^@]*$/, "", asset)
        if (index(asset, "/") > 0) { print; next }
        key = asset "-aarch64"
        if (index(rebuilt, " " key " ") == 0) { print; next }
        oldtag = rest; sub(/^.*@/, "", oldtag)
        $5 = "binaries:" asset "@" tag
        note = $1 " (" $4 "): " oldtag " -> " tag
        if (index(changed, " " key " ") > 0) {
            if (match($3, /\+.*\.[0-9]+$/)) {
                n = $3; sub(/^.*\./, "", n)
                head = substr($3, 1, length($3) - length(n))
                $3 = head (n + 1)
                note = note ", version " head n " -> " $3
            } else {
                printf "bins-record: %s (%s): the binary changed but its version %s did not — phones that have it will not see an update until the version moves (docs/maintainer/catalog.md, \"Rebuilding a binary\")\n", $1, $4, $3 > "/dev/stderr"
                note = note " (version " $3 " unchanged: bump it by hand)"
            }
        }
        print note > "/dev/stderr"
        print
    }' "$items" > "$tmp" 2> "$tmp.notes"
mv "$tmp" "$items"
grep -v '^bins-record:' "$tmp.notes" || true
grep '^bins-record:' "$tmp.notes" >&2 || true
rm -f "$tmp.notes"
echo "recorded $tag in SHA256SUMS and scripts/items.tsv"
