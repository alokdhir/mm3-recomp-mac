# mm3-recomp-mac

> **AI-assisted code:** like the project it builds on, most of this port was
> written with AI assistance (Claude Code). Expect rough edges; fixes welcome.

**Midtown Madness 3** (Xbox, 2003) running natively on Apple Silicon Macs.

This is a macOS port of [mm3-recomp](https://github.com/MattSG/mm3-recomp), a
static recompilation of the game: the original Xbox executable is translated
ahead of time into C, then compiled to native arm64 code. Nothing is emulated
at the CPU level. The Xbox's GPU commands are drawn with **Metal**, sound goes
through **Core Audio**, and controllers come in through Apple's
**GameController** framework (with rumble).

**Bring your own game.** This repository contains no game code, data or
assets. You build it from **your own disc image**; the build checks that the
game code matches the version the recompilation was made from.

## Requirements

- A Mac with Apple Silicon (M1 or later), macOS 14 Sonoma or later
- The Xcode Command Line Tools: `xcode-select --install`. Full Xcode is not
  needed; if it is installed, its Metal compiler precompiles the shaders,
  otherwise the game compiles them in about half a second when it starts.
- [Homebrew](https://brew.sh): `brew install cmake ninja python`
- About 10 GB free: the extracted game (2.6 GB), the generated code and build
- An image of **Midtown Madness 3** for the original Xbox. Known-good dumps:
  - USA redump `.iso` — SHA-1 `52cd998731eb67477b44c49c4152f56c0fc58a56`
  - EU XISO — SHA-1 `8ed003adaf504883afc980d2888df6125496d044`

  Other dumps (an extract-xiso rebuild, for example) work as long as the game
  executable inside matches; `setup.sh` tells you.

## Build

```sh
git clone --recursive https://github.com/alokdhir/mm3-recomp-mac.git
cd mm3-recomp-mac
scripts/setup.sh --iso "/path/to/Midtown Madness 3.iso"
```

The first run extracts the disc into `game_files/`, translates the game to C
(a few minutes) and builds. Later runs of `scripts/setup.sh` only rebuild.

Then open **`build/Midtown Madness 3.app`**, or run
`./build/third_party/mm3-recomp/mm3_recomp` from the repository folder to
see its log in the terminal. That app reads `game_files/` from the
repository; for a self-contained copy, with the game data inside the app
(`Contents/Resources/game_files`), run `scripts/package.sh` and drag
`build/dist/Midtown Madness 3.app` to Applications.

## Playing

| | Keyboard | Controller |
|---|---|---|
| Accelerate / brake | ↑ / ↓ | right / left trigger |
| Steer | ← / → | left stick |
| Handbrake | Space | A |
| Change camera | C | Black (right bumper) |
| Shift up / down (manual) | R / F | B / X |
| Bigger map | Ctrl | right stick click |
| Pause / start | Enter | Start (Menu) |
| Back | Esc / Backspace | B / View |
| Fullscreen | ⌘F | |

- **Graphics → Resolution**: 720p to 4K, or match the window; and
  **Graphics → Anti-aliasing**: off, 2x or 4x. Changes apply immediately
  and are remembered. The defaults are 1440p with 4x on Pro, Max and Ultra
  chips, 1080p with 2x on the base chips.
- The picture follows the window's shape (widescreen by default).
- Saves live in `~/Library/Application Support/Midtown Madness 3/

Xbox One, Series and PlayStation controllers work over Bluetooth or USB.

## Extra cars

Four imported cars can replace the extra slots' stand-in models. The models
are not in this repository (licences); download them, then build each from
its recipe in [`tools/car-import/recipes`](tools/car-import/recipes):

| Car | Download (Sketchfab, free account) | Recipe |
|---|---|---|
| Porsche 930 Turbo (silver / Guards Red) | [FREE 1975 Porsche 911 (930) Turbo](https://sketchfab.com/3d-models/free-1975-porsche-911-930-turbo-8568d9d14a994b9cae59499f0dbed21e), Lionsharp Studios, CC BY | `porsche930.json`, `porsche930_red.json` |
| Aston Martin DBS | [2009 Aston Martin DBS](https://sketchfab.com/3d-models/2009-aston-martin-dbs-aaef9c2b0b1a4af2815f30aa0893a00e), Galaxy Car Showroom, CC BY | `aston_dbs.json` |
| Porsche 911 GT3 (992) | [2022 Porsche 911 GT3 (992)](https://sketchfab.com/3d-models/2022-porsche-911-gt3-992-ba01afbaf32846e598db315be3507db3), Ddiaz Design, CC BY-NC-SA (from CSR2; personal use) | `porsche992gt3.json` |

Unzip each download where its recipe's `source` points (under
`~/Downloads`), then follow [`tools/car-import/README.md`](tools/car-import/README.md):
export with Blender, build the package, point the slot at it in
`third_party/mm3-recomp/tools/car-tools/car-mods/cars.local.json`, and apply.
`scripts/workshop.sh` opens Car Workshop (ratings, physics, gearing,
speedometer) and copies the applied data into the app.

## How it is put together

- `third_party/mm3-recomp` — the upstream project as a pinned submodule,
  with its runtime ([MattSG/xboxrecomp](https://github.com/MattSG/xboxrecomp),
  a fork of [sp00nznet/xboxrecomp](https://github.com/sp00nznet/xboxrecomp))
  nested inside. The port's changes to both are kept in `patches/` and
  applied by `setup.sh`, so the submodules stay clean upstream commits.
- `mac/` — what replaces the Windows host: the Metal renderer (a port of
  upstream's Direct3D 11 one, shaders in `nv2a.metal`), the AppKit window and
  input, Core Audio output, GameController/Core Haptics pads, and the app.
- `scripts/setup.sh` — disc check, extraction, translation, build.

The game logic runs as recompiled code; the Xbox kernel is reimplemented;
the GPU and audio chip are modelled and translated to Metal and Core Audio.

## Troubleshooting

- **"The game files were not found"**: run `setup.sh --iso …` first; a
  packaged app (`scripts/package.sh`) carries its game files inside it.
- **macOS won't open the app** (built on another Mac): System Settings →
  Privacy & Security → *Open Anyway*.
- **Debug → Save Recent Frames** (⌘⇧S) writes the last 48 frames to
  `~/Library/Logs/Midtown Madness 3 Frames/`, handy for reporting a visual
  glitch. The game keeps no log unless **Debug → Keep a Log** is on; from
  the next launch it then writes `~/Library/Logs/Midtown Madness 3.log`.

## Credits

This port stands on other people's work.

**Built on**

- [MattSG/mm3-recomp](https://github.com/MattSG/mm3-recomp) — Matt Graham's
  recompilation of Midtown Madness 3 and its Windows port: the translated
  game, its hand repairs, mods and the build this port extends.
- [lakshya16157/midtown-madness-3-PC-Native](https://github.com/lakshya16157/midtown-madness-3-PC-Native)
  — the PC Native fork whose car tools, gameplay repairs and runtime fixes
  mm3-recomp merged.
- [sp00nznet/xboxrecomp](https://github.com/sp00nznet/xboxrecomp) — the Xbox
  static recompilation toolkit and runtime (translator, kernel, hardware
  models), used through [MattSG/xboxrecomp](https://github.com/MattSG/xboxrecomp).
- [xemu-project/xemu](https://github.com/xemu-project/xemu) — the original
  Xbox emulator whose NV2A and MCPX audio models the runtime draws on.
- [capstone-engine/capstone](https://github.com/capstone-engine/capstone) —
  the disassembler the translator runs on.

**Which xboxrecomp in turn credits**:
[N64Recomp](https://github.com/N64Recomp/N64Recomp),
[XenonRecomp](https://github.com/hedge-dev/XenonRecomp),
[rexglue-sdk](https://github.com/rexglue/rexglue-sdk) and
[Cxbx-Reloaded](https://github.com/Cxbx-Reloaded/Cxbx-Reloaded).

**References for the Mac side** (studied, not included)

- [veritr1x/recomp-kit](https://github.com/veritr1x/recomp-kit), with
  [elforeign/nfs-most-wanted-mac](https://github.com/elforeign/nfs-most-wanted-mac)
  and [veritr1x/populous-recomp](https://github.com/veritr1x/populous-recomp)
  — recompiled PC games on Metal.
- [Wooloomooloo2/bloodborne_mac_port](https://github.com/Wooloomooloo2/bloodborne_mac_port)
  — lessons on Mac threading, faults and memory remapping.
- [3Shain/dxmt](https://github.com/3Shain/dxmt) (and
  [NerRobDog/dxmt](https://github.com/NerRobDog/dxmt)) — Direct3D on Metal;
  frame pacing ideas.

**Tools** (the optional texture-pack experiment in `scripts/upscale_textures.py`):
[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN),
[spandrel](https://github.com/chaiNNer-org/spandrel),
[PyTorch](https://github.com/pytorch/pytorch) and
[Pillow](https://github.com/python-pillow/Pillow).

## Licence

GPL-3.0-only, as [mm3-recomp](https://github.com/MattSG/mm3-recomp) is; see
[LICENSE](LICENSE). The patches to xboxrecomp keep its MIT licence, and its
xemu-derived parts their LGPL-2.1. This licence covers only this project's
code. It does not cover Midtown Madness 3, Xbox software, game assets or
trademarks, which belong to their owners; this project is not affiliated
with or endorsed by Microsoft or Digital Illusions.
