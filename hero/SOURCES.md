# Hero image sources

Each `hero/<name>.png` is an animated PNG (APNG) made from the upstream project's own demo
GIF, at the same pinned commit as `readme/<name>.md`, trimmed to 4 seconds and downscaled. Items
whose README has no motion (fastfetch, kitty, opencode — surveyed, no `.gif`/`.mp4`/`.webm`
reference in their READMEs) get no hero file.

| File | Source URL | Commit | License | Size | SHA-256 | Frames | Conversion command |
|---|---|---|---|---|---|---|---|
| `dawn.png` | https://github.com/andrewmd5/dawn/blob/0e9587477463ece157ef7eea66c9e34bc5c7737a/assets/Kitty.gif | `0e9587477463ece157ef7eea66c9e34bc5c7737a` | MIT (per catalog) | ~3.0 MiB | `5649c95d732c495e7feb74ab56f03f9d15231d45b679ecb4740e43f78df504c2` | 40 | `ffmpeg -y -t 4 -i Kitty.gif -vf "fps=10,scale=400:-2:flags=lanczos" -f apng -plays 0 dawn.png` (lowered below the 480/12fps default twice: 480@12fps gave ~4.6 MB, 480@10fps gave ~4.4 MB, this settled at 400@10fps for ~3.1 MB) |
| `sigye.png` | https://github.com/am2rican5/sigye/blob/f1a43ccdf621382fb1a4e652999ef7143c415b3f/assets/demo.gif | `f1a43ccdf621382fb1a4e652999ef7143c415b3f` | MIT (per catalog) | ~3.0 MiB | `de5ffcd3db2007168c7ba023303d24552113a56ed99268e579ba811b96d31211` | 48 | `ffmpeg -y -t 4 -i demo.gif -vf "fps=12,scale=480:-2:flags=lanczos" -f apng -plays 0 sigye.png` (the spec's `scale=600` gave ~4.6 MB, over budget, so lowered to the documented `scale=480` fallback) |
| `claude-code.png` | https://github.com/anthropics/claude-code/blob/d78be9481b889e11186ec4578b4f5e9301396e25/demo.gif | `d78be9481b889e11186ec4578b4f5e9301396e25` (default branch `main` HEAD, resolved 2026-09-24) | Proprietary (per catalog) | ~1.3 MiB | `6b89f5efdd33c355f00e226c879041e9895e5ed55e481361ae9720c47a0b083a` | 48 | `ffmpeg -y -t 4 -i demo.gif -vf "fps=12,scale=600:-2:flags=lanczos" -f apng -plays 0 claude-code.png` (fits at the spec's default settings) |
| `btop.png` | a screen recording of this build of btop running in Termux:Launcher through the privileged lane on a Nothing Phone (2), 2026-09-25 | - | Apache-2.0 (per catalog) | ~2.4 MiB | `16fe9f5460d6c49c2f830cb9c29c2a8abde4118931144419870da4e8afb11739` | 20 | `ffmpeg -y -ss 4 -t 4 -i screen.mp4 -vf "crop=1012:1166:34:236,fps=5,scale=480:-2:flags=lanczos" -f apng -plays 0 -pred mixed btop.png` (btop redraws every 1.7 s, so 5 fps loses nothing; 12 fps gave ~8.6 MB) |

Source GIFs were fetched at the pinned commit via `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>`
for `dawn` and `claude-code`; for `sigye`, that URL 404'd (see `readme/SOURCES.md`), so its GIF was
pulled via `gh api repos/am2rican5/sigye/git/blobs/<blob-sha>` (base64-decoded) — the contents API's
inline `content` field is empty for files over ~1 MB, so the git blobs endpoint was used instead.

Surveyed and found no motion (no hero file):
- `fastfetch` — README references only static PNG screenshots and shield badges.
- `kitty` — README (`README.asciidoc`) has only a build-status badge image, no demo GIF.
- `opencode` — README references only a static logo SVG and a static screenshot PNG.
