# Termux Launcher binaries

Prebuilt `aarch64` binaries for three terminal tools that
[Termux Launcher](https://github.com/PickleHik3/termux-launcher) shows off but does not ship inside
the APK: `kitten`, a Fastfetch patched to animate Kitty-protocol GIFs, and the `sigye` clock.

They exist because building them on a phone ranges from slow to impossible — `kitten` in particular
cannot practically be built in Termux at all, because kitty's generated Go sources come from a
generator that needs a built kitty first.

`setup-launcher` installs them from here. Nothing else in the launcher depends on this repository.

## What is here

| File | Version | Source |
|---|---|---|
| `bin/kitten-aarch64` | kitty `v0.48.2` (`2cb1d95c`), unmodified | [kovidgoyal/kitty](https://github.com/kovidgoyal/kitty) |
| `bin/fastfetch-aarch64` | Fastfetch `v2.67.0` (`9c7cfb86`) + `recipes/0001-kitty-animation.patch` | [fastfetch-cli/fastfetch](https://github.com/fastfetch-cli/fastfetch) |
| `bin/sigye-aarch64` | Sigye `v0.6.0` (`0f0b8caa`) + `recipes/0001-termux-clipboard.patch` | [am2rican5/sigye](https://github.com/am2rican5/sigye) |

`SHA256SUMS` covers all three. `setup-launcher` verifies its own pinned digest before installing
anything, so a tampered file is refused rather than run.

## Installing

Through the launcher's setup script, which is the intended path:

```sh
setup-launcher      # option 1, or option 3 and pick the tools
```

By hand, into `~/.local/bin` — never `$PREFIX/bin`, which a bootstrap reinstall deletes whole and
which APT owns the name `fastfetch` in:

```sh
mkdir -p ~/.local/bin
curl -fsSLo ~/.local/bin/kitten \
  https://raw.githubusercontent.com/PickleHik3/termux-launcher-binaries/main/bin/kitten-aarch64
chmod +x ~/.local/bin/kitten
sha256sum ~/.local/bin/kitten     # compare against SHA256SUMS
```

Make sure `~/.local/bin` comes before `$PREFIX/bin` in `PATH`, or the APT `fastfetch` wins.

## Which editions these work on

Built against the **`com.termux`** prefix (`/data/data/com.termux/files/usr`).

- **`kitten`** — static Go, no shared-library dependencies at all. Runs on any edition.
- **`sigye`** — links only Bionic (`libc`, `libm`, `libdl`). Runs on any edition. Its `u` and `i`
  clipboard keys shell out to `termux-clipboard-get`/`-set`, so they need `termux-api`.
- **`fastfetch`** — has a `RUNPATH` into the `com.termux` prefix and needs `libandroid-glob`
  (`pkg install libandroid-glob`). It will not run on `io.vaj.tl` or the Nix edition. Image logos
  are loaded through `dlopen`, so `pkg install imagemagick chafa` is what makes the GIF logo work;
  without them Fastfetch falls back to text.

The Nix edition needs none of this — nixpkgs has kitty, fastfetch and their dependencies, and the
animated-logo build is a toolkit there.

## Known limits

- **`kitten update-self` fails.** These are `android/arm64` builds and upstream publishes no Android
  asset, so the updater 404s. Update by pulling a newer file from here.
  The Android build is not optional: a `linux/arm64` kitten dies with `SIGSYS: bad system call` on
  `faccessat2`, which Android's seccomp filter kills, and kitten issues it during package
  initialisation — so every subcommand crashes before it runs.
- **`kitten @` does nothing useful.** There is no kitty remote-control endpoint to talk to.
- **`kitten clipboard`** guesses MIME types from file extensions.
- **Fastfetch's animation** relies on the terminal continuing playback on its own clock, which
  Termux Launcher does and most terminals do not.

## Corresponding source

`kitten` is GPL-3.0-only. The complete corresponding source is kitty at tag `v0.48.2`, unmodified:

```sh
git clone --depth 1 --branch v0.48.2 https://github.com/kovidgoyal/kitty
```

`recipes/` holds the exact scripts these binaries were produced with, including the sysroot
assembly and every flag. They need a Linux host with the Android NDK, Go, and rustup — no Docker
and no `termux-packages` checkout. The same scripts live in the launcher repository under
`recipes/cross/`.

If any source here becomes hard to obtain, open an issue and it will be provided.

## Licences

- kitty / `kitten` — GPL-3.0-only, `licenses/kitty-GPL-3.0-only.txt`
- Fastfetch — MIT, `licenses/fastfetch-MIT.txt`, modified by `recipes/0001-kitty-animation.patch`
- Sigye — MIT, `licenses/sigye-MIT.txt`, modified by `recipes/0001-termux-clipboard.patch`

Fastfetch loads Chafa (LGPL-3.0-or-later) and ImageMagick (`ImageMagick` licence) through `dlopen`
at runtime; neither is linked into or redistributed with the binary here.

These are convenience builds of other people's software. They carry no warranty, and bugs in them
are this repository's problem, not upstream's — report them
[here](https://github.com/PickleHik3/termux-launcher/issues).
