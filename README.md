# Termux Launcher binaries

Prebuilt `aarch64` binaries for four terminal tools that
[Termux Launcher](https://github.com/PickleHik3/termux-launcher) shows off but does not ship inside
the APK: `kitten`, a Fastfetch patched to animate Kitty-protocol GIFs, the `dawn` writing pad and
the `sigye` clock — plus the musl runtime that lets `tlstore` run Claude Code and opencode inside a
Termux prefix.

They exist because building them on a phone ranges from slow to impossible — `kitten` in particular
cannot practically be built in Termux at all, because kitty's generated Go sources come from a
generator that needs a built kitty first.

`tlstore`, the launcher's little package store, installs them from here, against a digest pinned
in its catalog. Nothing else in the launcher depends on this repository.

## What is here

| File | Version | Source |
|---|---|---|
| `bin/kitten-aarch64` | kitty `v0.48.2` (`2cb1d95c`), unmodified | [kovidgoyal/kitty `v0.48.2`](https://github.com/kovidgoyal/kitty/tree/v0.48.2) |
| `bin/fastfetch-aarch64` | Fastfetch `v2.67.0` + `recipes/termux/fastfetch/0001-kitty-animation.patch`, for the `com.termux` prefix | [fastfetch-cli/fastfetch `9c7cfb86`](https://github.com/fastfetch-cli/fastfetch/tree/9c7cfb864ff9154ffe951fae191c14d60bb91544) |
| `bin/fastfetch-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [fastfetch-cli/fastfetch `9c7cfb86`](https://github.com/fastfetch-cli/fastfetch/tree/9c7cfb864ff9154ffe951fae191c14d60bb91544) |
| `bin/dawn-aarch64` | dawn `0.1.3+0e958747` + `recipes/0001-dawn-termux-clipboard.patch`, for the `com.termux` prefix | [andrewmd5/dawn `0e958747`](https://github.com/andrewmd5/dawn/tree/0e9587477463ece157ef7eea66c9e34bc5c7737a) |
| `bin/dawn-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [andrewmd5/dawn `0e958747`](https://github.com/andrewmd5/dawn/tree/0e9587477463ece157ef7eea66c9e34bc5c7737a) |
| `bin/sigye-aarch64` | Sigye `v0.6.0` + `recipes/termux/sigye/0001-termux-clipboard.patch` | [am2rican5/sigye `0f0b8caa`](https://github.com/am2rican5/sigye/tree/0f0b8caaccb4ca01ab5d1fad1237c4a01a49766f) |
| `bin/musl-loader-aarch64` | musl `1.2.5` + `recipes/cross/0001-musl-ld-preload-var.patch` + prefix paths, for the `com.termux` prefix | [musl-1.2.5.tar.gz](https://musl.libc.org/releases/musl-1.2.5.tar.gz) |
| `bin/musl-loader-io.vaj.tl-aarch64` | the same build, for the `io.vaj.tl` prefix | [musl-1.2.5.tar.gz](https://musl.libc.org/releases/musl-1.2.5.tar.gz) |
| `bin/musl-libstdcxx-aarch64` | GCC `14.2.0` `libstdc++.so.6`, musl-linked, unmodified | [Alpine `libstdc++-14.2.0-r6`](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/libstdc++) |
| `bin/musl-libgcc-aarch64` | GCC `14.2.0` `libgcc_s.so.1`, musl-linked, unmodified | [Alpine `libgcc-14.2.0-r6`](https://pkgs.alpinelinux.org/package/v3.22/main/aarch64/libgcc) |

Fastfetch and dawn are here twice because each resolves a library through a path fixed at link
time, so one build per install prefix is needed; `kitten` and `sigye` are prefix-independent and
serve every edition. `tlstore` reads `$PREFIX` and installs the right one.

The last two are not built here and not patched: they are GCC's runtime libraries as Alpine
packages them, taken out with `recipes/fetch-musl-runtime.sh` against a pinned digest. They exist
because a binary built for musl elsewhere wants musl's C++ library, and Termux's is a Bionic one the
musl loader cannot load.

`SHA256SUMS` covers all ten. `tlstore` verifies the digest its catalog pins before installing
anything, so a tampered file is refused rather than run.

## Installing

Through the store, which is the intended path:

```sh
tlstore install kitten dawn sigye
```

By hand, into `~/.local/bin` — where `tlstore` puts them, and never `$PREFIX/bin`, which a
bootstrap reinstall deletes whole and which APT owns the name `fastfetch` in:

```sh
mkdir -p ~/.local/bin
curl -fsSLo ~/.local/bin/kitten \
  https://raw.githubusercontent.com/PickleHik3/termux-launcher-binaries/main/bin/kitten-aarch64
chmod +x ~/.local/bin/kitten
sha256sum ~/.local/bin/kitten     # compare against SHA256SUMS
```

Make sure `~/.local/bin` comes before `$PREFIX/bin` in `PATH`, or the APT `fastfetch` wins.

## Which editions these work on

- **`kitten`** — static Go, no shared-library dependencies at all. Runs on any edition.
- **`sigye`** — links only Bionic (`libc`, `libm`, `libdl`). Runs on any edition. Its `u` and `i`
  clipboard keys shell out to `termux-clipboard-get`/`-set`, so they need `termux-api`.
- **`dawn`** — one build per prefix, for the same reason as Fastfetch and with one library
  instead of several: it links `libcurl` (`pkg install libcurl`) and finds it through its own
  `RUNPATH`, because Termux clears `LD_LIBRARY_PATH` on Android 7+. The `com.termux` build does not
  start under `io.vaj.tl` and the other way round. Everything else it parses — markdown, YAML,
  regular expressions, images — is vendored into the binary. Copy and paste go through the terminal
  rather than the system: upstream shells out to `xclip`, which no phone has, so the patch replaces
  that with OSC 52. Termux Launcher answers it, including the read that makes paste work, unless
  that read has been turned off in its Terminal I/O settings.
- **`fastfetch`** — one build per prefix: `fastfetch-aarch64` for `com.termux`
  (`/data/data/com.termux/files/usr`), `fastfetch-io.vaj.tl-aarch64` for `io.vaj.tl`. Each has a
  `RUNPATH` into its own prefix and needs `libandroid-glob` there (`pkg install libandroid-glob`),
  so the wrong one does not start at all — the linker cannot find `libandroid-glob.so` and the
  process dies before `main`. Its home directory comes from `recipes/termux-pwd-polyfill.h` and is
  fixed at the same time, because Bionic reports `pw_dir="/data"` for an app uid and Fastfetch reads
  passwd in preference to `$HOME`. Image logos are loaded through `dlopen`, so
  `pkg install imagemagick chafa` is what makes the GIF logo work; without them Fastfetch falls
  back to text.

The Nix edition needs none of this — nixpkgs has kitty, fastfetch and their dependencies, and the
animated-logo build is a toolkit there.

Both fastfetch builds were rebuilt 2026-09-01 with the 8-bit depth fix (`SetImageDepth` before the
Kitty transmission), the `io.vaj.tl` one against a sysroot from that edition's own repository
(`https://repo.pathayam.xyz`); `kitten` and `sigye` were built 2026-08-16 with NDK `27.2.12479018`.

## The musl loader, and Claude Code

Claude Code is distributed only as a Bun-compiled binary linked against musl
(`@anthropic-ai/claude-code-linux-arm64-musl` on npm). Android has Bionic, not musl, so the binary
needs a musl dynamic loader — and stock musl does not work on Android either: it reads
`/etc/resolv.conf`, which does not exist there, so every DNS lookup times out, and it dies on the
Bionic library Termux puts in `LD_PRELOAD` (termux-exec). `recipes/build-musl-loader.sh` builds
musl 1.2.5 with the resolver paths moved under the prefix and `LD_PRELOAD` renamed to
`MUSL_LD_PRELOAD`, so Termux's variable passes through untouched to every child shell and shebang
handling keeps working there. One loader per prefix, because the resolver path is a string in the
library. The loader is built natively in Termux (`pkg install clang make patch`), from any edition.

## opencode

opencode ships a musl build on npm (`opencode-linux-arm64-musl`), so it takes the same path as
Claude Code: the store downloads it, checks the registry's own sha512, and points its interpreter
at the loader. It needs one thing Claude Code does not — `libstdc++.so.6` and `libgcc_s.so.1`,
which is what the two library files above are for. `tlstore` copies them in beside the loader,
where the rpath it sets already looks.

Verified 2026-09-22 on a Nothing A065 running Android 16: the libraries resolve under the patched
loader, and `opencode --version` and `--help` run. Its own installer picks a build by asking `ldd`,
which on Android chooses the glibc one and fails, so the store makes that choice instead.

Claude Code itself is not in this repository: it is Anthropic's proprietary build, and at 208 MB it
is over GitHub's file limit anyway. `tlstore` downloads the npm tarball from
registry.npmjs.org, checks it against the registry's own sha512, points its interpreter at the
loader with `patchelf`, and installs a `~/.local/bin/claude` wrapper that turns off the built-in
updater (an updated binary would arrive unpatched and fail to start). Verified 2026-09-06 inside
the com.termux app process on a Nothing A065 running Android 16: startup, DNS, TLS to
api.anthropic.com, and the interactive UI.

## Known limits

- **`kitten update-self` fails.** These are `android/arm64` builds and upstream publishes no Android
  asset, so the updater 404s. Update by pulling a newer file from here.
  The Android build is not optional: a `linux/arm64` kitten dies with `SIGSYS: bad system call` on
  `faccessat2`, which Android's seccomp filter kills, and kitten issues it during package
  initialisation — so every subcommand crashes before it runs.
- **`dawn` needs `libcurl` present**, or it does not start: `pkg install libcurl`. `tlstore`
  installs it with the item; a hand-installed copy has to be given it.
- **`kitten @` does nothing useful.** There is no kitty remote-control endpoint to talk to.
- **`kitten clipboard`** guesses MIME types from file extensions.
- **Fastfetch's animation** relies on the terminal continuing playback on its own clock, which
  Termux Launcher does and most terminals do not.
- **Fastfetch places its logo through Kitty's Unicode placeholders** (`U=1`), the mechanism
  `kitten icat --unicode-placeholder` uses, so the terminal must implement placeholders and not
  only the graphics protocol. One that ignores `U=1` stores the image, draws nothing, and shows
  the placeholder cells as missing glyphs. Set `"printRemaining": true` when the logo is taller
  than the module list, or the shell prompt clears the bottom of it.

## Corresponding source

`kitten` is GPL-3.0-only. The complete corresponding source is kitty at tag `v0.48.2`, unmodified:

```sh
git clone --depth 1 --branch v0.48.2 https://github.com/kovidgoyal/kitty
```

`dawn` is MIT, so its patched source is not an obligation, but the patch that produced these two
binaries is in `recipes/0001-dawn-termux-clipboard.patch` and applies cleanly to `0e958747`:

```sh
git clone https://github.com/andrewmd5/dawn && cd dawn
git checkout 0e9587477463ece157ef7eea66c9e34bc5c7737a
git submodule update --init --recursive
git apply /path/to/recipes/0001-dawn-termux-clipboard.patch
```

`recipes/` holds the exact scripts these binaries were produced with, including the sysroot
assembly and every flag. They need a Linux host with the Android NDK, Go, and rustup — no Docker
and no `termux-packages` checkout. The same scripts live in the launcher repository under
`recipes/cross/`.

If any source here becomes hard to obtain, open an issue and it will be provided.

## Licences

- kitty / `kitten` — GPL-3.0-only, `licenses/kitty-GPL-3.0-only.txt`
- Fastfetch — MIT, `licenses/fastfetch-MIT.txt`, modified by `recipes/termux/fastfetch/0001-kitty-animation.patch`
- Sigye — MIT, `licenses/sigye-MIT.txt`, modified by `recipes/termux/sigye/0001-termux-clipboard.patch`
- dawn — MIT, `licenses/dawn-MIT.txt`, modified by `recipes/0001-dawn-termux-clipboard.patch`
- `libstdc++.so.6` and `libgcc_s.so.1` — GCC 14.2.0, GPL-3.0-or-later with the GCC Runtime Library
  Exception, `licenses/gcc-runtime-GPL-3.0-with-exception.txt`, unmodified. The corresponding
  source is GCC 14.2.0 as Alpine builds it:
  [aports `main/gcc`](https://gitlab.alpinelinux.org/alpine/aports/-/tree/v3.22-stable/main/gcc)
  over [gcc-14.2.0.tar.xz](https://ftp.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz)

Fastfetch loads Chafa (LGPL-3.0-or-later) and ImageMagick (`ImageMagick` licence) through `dlopen`
at runtime; neither is linked into or redistributed with the binary here.

These are convenience builds of other people's software. They carry no warranty, and bugs in them
are this repository's problem, not upstream's — report them
[here](https://github.com/PickleHik3/termux-launcher/issues).

## Recipes

`recipes/` is how every binary here is built, moved from the launcher repository so the
sources and the artefacts live together:

- `recipes/cross/` — host cross-builds with the Android NDK: fastfetch, dawn, sigye, kitten, the
  musl loader, and `termux-sysroot.sh` that assembles a sysroot from Termux's own `.deb`s.
- `recipes/termux/` — the same tools built on the phone, in Termux.
- `recipes/nix/` — the Nix edition's overlay.

Each `cross` script honours `TL_NDK`, `TL_SYSROOT`, `TL_OUT` and `TL_BUILD_DIR`; see
`recipes/cross/README.md`.
