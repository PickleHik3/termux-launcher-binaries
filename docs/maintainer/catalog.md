# Keeping the tlstore catalog current

How an agent adds, updates or removes an item in tlstore, and what has to happen before the
change reaches a phone. The user-facing side is `docs/user/Tlstore.md`; the design of the store's
screens is `docs/REVISION-6.md` (Revision 5 still describes the engine, the TSV contract and the
progress stream).

This repository (`PickleHik3/tlstore`, renamed from termux-launcher-binaries 2026-09-24; local
checkout at `~/Projects/termux-launcher/tlstore`) is
the store's whole home: the engine source, the catalog inputs, the UI crate, the scripts and the
docs live here together, and a `dist/` of built, signed release files is what a tag actually ships.
The launcher (`PickleHik3/termux-launcher`) consumes a tagged `dist/` by pinned digest — nothing
in the launcher builds or signs any of this.

## The pieces

| Piece | Where | Owner |
|---|---|---|
| Item list (hand-maintained) | `scripts/items.tsv` | you edit this |
| Engine source (POSIX sh) | `engine/tlstore` | edit, `scripts/test.sh`, `scripts/sign.sh` |
| Trusted key (source) | `engine/trusted.pub` | the maintainer's minisign public key |
| Store UI (Rust) | `ui/` | `scripts/build-ui.sh --install` after any `src/` change |
| Pictures | `scripts/pictures/<name>.jpg` + `SOURCES.md` | you, with the conversion in `SOURCES.md` |
| Release outputs (built, signed) | `dist/{tlstore,tlstore.minisig,catalog.tsv,catalog.tsv.minisig,trusted.pub,tlstore-ui-arm64-v8a,tlstore-ui-x86_64}` | `scripts/release.sh <tag>` — never hand-edited |
| Binaries the catalog installs | this repository, per tag, `SHA256SUMS` | `recipes/cross` and `recipes/termux` build them |
| Launcher-side install | `app/src/main/java/com/termux/app/store/TlstoreInstaller.java` in `PickleHik3/termux-launcher` | writes script, catalog, key and UI binary into `$PREFIX` on every start, from a pinned tag's `dist/` |

The phone reads `catalog.tsv` by fixed column position and requires at least ten columns. New
columns land only at the end, and a hidden part carries `-` in every descriptive column and `0`
in `setup`/`featured`.

## Adding or changing an item

1. **Pin the payload.** A `binary`/`file` source is `launcher:<path>@<tag or commit>` (a
   launcher-owned template, fetched from `PickleHik3/termux-launcher`), `binaries:<asset>@<tag>`
   (this repository, a tag's `dist/` or a path in it) or an immutable URL; `npm-musl` is
   `npm:<package>#<exe>`; `pkg` names Termux packages. Never a branch. For a new binary, build it
   with the recipe, publish it under a tag in this repository, and take its digest from that tag's
   `SHA256SUMS`.
2. **Edit `items.tsv`.** The header comment defines every column and its rule (length limits,
   allowed values). Revision 6 reads: `category`, `upstream`, `setup`, `standfirst`, `author`,
   `licence`, `size`, `picture`, `featured`, `readme-skip`, `readme` (the pinned-content addendum).
   `does1..3`, `try` and `notes` are no longer shown; fill them with `-` for a new item.
   - `standfirst`: one line, at most 42 characters, lower case, no brand name, no full stop. It is
     the only sentence we write about the item.
   - `readme-skip`: `|`-separated headings of the upstream README to leave out (developer-facing
     sections). Installation, Building, Contributing, Licence, Changelog, Sponsors and similar are
     dropped by default already.
   - `picture`: a source pointing at a hero picture in `scripts/pictures/<name>.jpg`. A new item
     points at it with `binaries:scripts/pictures/<name>.jpg@<tag>` — a path source resolved
     against this repository's own `SHA256SUMS` at that tag (the old `launcher:scripts/tlstore/
     pictures/…@<commit>` sources still on a few items are pinned at a commit in the launcher
     repository from before the store moved here; they keep working and are left alone, but no new
     item should add one). Convert the upstream hero image as `pictures/SOURCES.md` says and add a
     row there with the source and its licence.
   - `readme`: a `launcher:`/`binaries:` source for a pinned copy of the item's README, read
     instead of the upstream one; `-` to keep fetching upstream (most items). Pin one when the
     upstream README does not render well as-is (heavy badges, a build matrix table, prose that
     assumes a desktop) — write a trimmed copy instead of relying on `readme-skip` alone.
   - `demo`: unchanged (a `launcher:`/`binaries:` source for a short clip of `try` working), but
     now digest-checked like `picture` — `build-catalog.sh` computes its `demo-digest` the same
     way it already computes `picture-digest`.
3. **Build the catalog.**
   ```sh
   scripts/build-catalog.sh              # SHA256SUMS defaults to this repo's own
   scripts/build-catalog.sh /path/to/SHA256SUMS   # only if you need a different one
   ```
   It computes digests (network for plain URLs), bumps the serial (`YYYYMMDDNN`, only forward) and
   writes `dist/catalog.tsv`. A source whose digest cannot be computed stops the build.
4. **Test the engine.** `bash scripts/test.sh` must end `failed 0`. It runs `engine/tlstore` under
   `/bin/sh` and `bash --posix`; dash, busybox and shellcheck run too when installed.
5. **Sign.** `bash scripts/sign.sh` signs `dist/catalog.tsv` and `dist/tlstore`. The key is
   `~/.config/vaj-apt/tlstore-minisign.key`, encrypted, outside the tree: the developer runs this
   step (`! bash scripts/sign.sh` in a Claude session). Phones verify the signature only when they
   refresh from origin, so sign before every push, not before a local test install. In practice
   this happens inside the two-pass release flow below, not on its own.
6. **Check the UI against it.** In `ui/`: `cargo test`, and for a look at the result without a
   phone, the preview renderer:
   ```sh
   cargo run --features shot -- --shot 53x26 --screen item:<name> --out /tmp/item.png
   cargo run --features shot -- --shot-all --out /tmp/frames/
   ```
   It renders from `tests/fixtures/store`, so a new item needs a row in the fixture `list.tsv`,
   an `info/<name>` file and a `readme/<name>.md` to appear there.
7. **Commit** `items.tsv` and any picture. `dist/` is not committed by hand at this step — cut a
   release (below) once the item is ready to ship.

## Cutting a release

`dist/` is never hand-edited. `scripts/release.sh <tag>` builds it from the sources
(`engine/tlstore`, `engine/trusted.pub`, `scripts/items.tsv`, `ui/`) and writes the lock block the
launcher pins against. Signing needs the developer's passphrase, so this is two passes:

1. **`scripts/release.sh <tag> --prepare`** — copies `engine/tlstore` and `engine/trusted.pub`
   into `dist/`, runs `build-catalog.sh` (writing `dist/catalog.tsv`), and checks
   `dist/tlstore-ui-<abi>` freshness against the working tree (`scripts/check-dist.sh`, the
   `ui-src-hash.sh` check the launcher's own `checkTlstoreUiFresh` gradle task used to run). Run
   `scripts/build-ui.sh --install` first if the UI needs rebuilding.
2. The developer runs **`scripts/sign.sh`** by hand (the key never touches an agent session).
3. **`scripts/release.sh <tag>`** (no `--prepare`) — verifies both signatures against
   `engine/trusted.pub` with `minisign -Vm`, refuses if anything is missing or stale, writes
   `dist/<file>` lines into `SHA256SUMS` (replacing the existing `dist/` lines, leaving every other
   line untouched), and prints the lock block:
   ```
   tag <tag>
   <sha256>  tlstore
   <sha256>  tlstore.minisig
   <sha256>  catalog.tsv
   <sha256>  catalog.tsv.minisig
   <sha256>  trusted.pub
   <sha256>  tlstore-ui-arm64-v8a
   <sha256>  tlstore-ui-x86_64
   ```

`release.sh` never tags or pushes; that is the orchestrator's call once the lock block is in hand.

### From GitHub, without a laptop

`.github/workflows/release.yml` runs the same three passes on a runner, then commits `dist/` and
`SHA256SUMS`, tags and pushes, and prints the lock block in the run summary. Start it from the
Actions tab, the GitHub app, or `gh workflow run release.yml [-f tag=<tag>]`; with no tag it uses
today's date, suffixed `-2`, `-3`… when that is taken. It runs `scripts/test.sh` first and rebuilds
`tlstore-ui` only when `scripts/check-dist.sh` says `ui/` changed. Binaries, heroes and readmes are
published as committed, so build and commit those before running it.

It signs with two repository secrets, set once from the machine that holds the key:

```sh
gh secret set TLSTORE_SIGNING_KEY -R PickleHik3/tlstore < ~/.config/vaj-apt/tlstore-minisign.key
gh secret set TLSTORE_SIGNING_KEY_PASSWORD -R PickleHik3/tlstore   # prompts for the password
```

`scripts/sign.sh` reads the password from `TLSTORE_SIGNING_KEY_PASSWORD` when it is set. With the
key in the repository's secrets, anyone who can run workflows here can publish a catalog phones
trust: keep write access to yourself.

## Pinning a readme or a hero picture

Most items just fetch the upstream README (`readme` stays `-`). Pin one when the upstream page
does not render well as-is — heavy badges, a build matrix, prose written for a browser — and a
`readme-skip` heading list alone is not enough.

1. **Write the trimmed readme.** A plain markdown file, following the item page's rendering rules
   (`docs/REVISION-6.md`, "Item").
2. **Make the hero, if the item wants an animated one.** From a short screen recording or gif of
   the item running:
   ```sh
   scripts/make-hero.sh clip.mp4 hero.png
   ```
   4 seconds, 12 fps, 600 px wide, looping APNG, full frames (needs `ffmpeg`).
3. **Commit both into this repository**, under `readme/<name>.md` and `hero/<name>.png`, add their
   lines to that tag's `SHA256SUMS`, and push a tag the way any other binary asset does.
4. **Point `items.tsv` at them.** `readme` (and, for a hero picture pinned the same way, `picture`
   or `demo`) takes `binaries:<path>@<tag>` — a path with a slash resolves to that exact file in
   the tag, not the per-processor `bin/<asset>-aarch64` a bare asset name resolves to. Leave
   `readme-digest`/`demo-digest` alone: `build-catalog.sh` computes them from the same
   `SHA256SUMS`, by that repo-relative path, the way it already computes `picture-digest`.
5. **Build, test, release** as above. A pinned readme that fails its digest check on a phone is a
   hard error (the `tlstore picture` convention: no silent fall back to the upstream copy).

## Changing the engine or the UI

- Script changes: edit `engine/tlstore`, keep it POSIX (`dash`-clean), add a `scripts/test.sh`
  case, cut a release to re-sign. `TLSTORE_VERSION` in the script is what phones compare when
  they self-update from origin.
- UI changes: any file under `ui/src`, `ui/Cargo.toml` or `ui/Cargo.lock` changes the source hash
  baked into the binaries. Run `ANDROID_HOME=~/Android/Sdk bash scripts/build-ui.sh --install`
  before cutting a release, or `scripts/release.sh <tag> --prepare` refuses with a stale
  `dist/tlstore-ui-<abi>`. Never enable the `shot` feature in the shipped build.
- The launcher's installer rewrites everything on the phone when the launcher's package update
  time changes, and rewrites the UI binary whenever the bundled bytes differ; a same-version debug
  reinstall therefore still picks the new binary up on the next launcher start.

## Privileged items (priv=shizuku)

Some tools need the whole phone in view — btop wants every process, every mount and every network
interface, and a Termux uid only sees its own. A `binary` row with `priv=shizuku` in `options` is
run by the launcher as the shell uid (2000) instead. End to end:

1. **tlstore** downloads the binary to `~/.local/lib/tlstore/priv/<name>`, off PATH, and writes a
   wrapper at `~/.local/bin/<name>` that runs `exec "~/.local/bin/tl-priv" run "<that path>" "$@"`.
   Both files are recorded, `remove` deletes both, `info` names both. The row must `requires`
   `tl-priv` and carry `host=launcher` (plain Termux has no lane) and a `min-launcher=` naming the
   first launcher release that has one.
2. **tl-priv** (`recipes/cross/tl-priv/tl-priv.c`, built by `build-tl-priv.sh`; a hidden `binary`
   item) connects to the launcher's abstract unix socket `\0<package>.priv` and sends one line:
   `tlpriv1 <TAB> run <TAB> <path> <TAB> <TERM> <TAB> <rows> <TAB> <cols> [<TAB> <arg>]…`. It gets back
   `ok <pid>` with the pty master over `SCM_RIGHTS`, or `err <message>`, which it prints and exits
   126 with (127 when nothing listens). Then it relays the pty to the terminal in raw mode, forwards
   window-size changes, and exits with the code from the closing `exit <code>` line. Closing the
   socket ends the child.
3. **The launcher's service** (in `PickleHik3/termux-launcher`) copies the binary to
   `/data/local/tmp/tl/bin/<name>` and, through its Shizuku `UserService`, spawns it there in a pty
   as uid 2000 with `HOME=/data/local/tmp/tl/home/<name>`, `LANG=C.UTF-8` and `PATH=/system/bin`
   — no Termux prefix exists on that side, which is why the binary must be fully static with no
   prefix baked in (see `recipes/cross/README.md`). The launcher allowlists what it will run by the
   catalog digest: the row's `digest` is the identity the service checks against, so a rebuilt
   binary means a new tag, a new digest and a new catalog before it runs.

To add another one: build it static and prefix-free with a `recipes/cross/build-<name>.sh` (the
btop script is the model — Bionic's `libc.a` through the NDK's `-static`, and mind that Bionic has
no `pthread_cancel`), publish it under a tag, add a `binary` row with `priv=shizuku`, `requires`
`tl-priv`, `host=launcher` and `min-launcher=`, and note in the item's copy what the shell uid
cannot do — signal other uids' processes, for one. Anything the tool reads from `/sys` that Android
refuses the shell uid (btop's network counters, for instance) needs a `/proc` fallback patched in,
not a note. The engine's tests cover the install/remove shape (`privbin` in `scripts/test.sh`);
the lane itself is verified on a phone.

## Removing an item

Delete its row (and its parts, if nothing else needs them), rebuild, test, release. Phones that
have it installed keep it; `tlstore remove <name>` still works from the old catalog they cached.

## Release cut

A launcher release pins one `dist` tag from this repository in its own build (see `AGENTS.md`
here and the launcher's own docs for exactly where); nothing else is needed per launcher edition —
the catalog is edition-neutral except for `prefixes`, where a row can name one app package when a
binary is built per prefix (see `recipes/cross/README.md` in this repository).
