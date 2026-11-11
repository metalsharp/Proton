# macOS (Apple Silicon) target

Builds Proton natively on arm64 macOS, with MetalSharp Wine and its FEX fork. Design: `SPEC.md`.

## Build

```bash
git submodule update --init wine FEX darwin/metalsharp-wine
```

```bash
git -C FEX submodule update --init --recursive
```

```bash
make proton
```

`make proton` configures `build/build-<branch>-local/` with `--target-os=darwin --target-arch=arm64` and builds `dist/` there. No container is used. To work in the build directory directly:

```bash
mkdir -p build/mac && cd build/mac && ../../configure.sh --target-os=darwin --target-arch=arm64 --build-name=mac && make
```

Add the add-on sources first if you want them (`make ADDONS=` builds without):

```bash
git submodule update --init mullion winemetalgl wfdxcompat dxvk
```

Stages can be built one at a time: `make deps`, `make wine`, `make fex`, `make payloads`, `make addons`, `make tests`, `make dist`. Each stage's output goes to `logs/` in the build directory. `make check-host` lists missing tools.

## What you need

- Xcode as the active developer directory, with the Metal toolchain.
- Homebrew: cmake, ninja, meson, pkgconf, nasm, bison, flex, gettext.
- **An llvm-mingw toolchain with ARM64X runtimes.** For now it is cloned from an existing MetalSharp Wine build tree, named by `SEED` (default `/Volumes/AverySSD/MetalSharp-Wine-Arm64-FEX`). Building it from nothing is not wired up yet.

## How it works today (stage 1)

`darwin/make/darwin.mk` gives Proton's targets to MetalSharp Wine's own build scripts, which live in the `darwin/metalsharp-wine` submodule (the `main` branch of `metalsharp/MetalSharp-Wine`). The build directory is laid out as the checkout those scripts expect. Wine is built in a copy of the `wine` submodule, because Wine's macOS build has to run in its source tree.

The result is in Proton's layout: `dist/files` is the relocatable Wine tree, next to `proton`, `filelock.py` and `version`.

## Status

`docs/macos/M1-STATUS.md` has what builds, what was run, and how the result compares with MetalSharp Wine 6.0.

Not done yet:

- The VKD3D-Proton lane and MoltenVK 1.4.3. Everything else MetalSharp Wine 6.0 ships is in `dist/files`: Wine, FEX, Mullion, WineMetalGL, WFDXCompat, DXVK-MacOS, innoextract, cabextract, and the files `wine.inf` installs into a prefix.
- Signing and the app bundle. An unsigned build runs x86_64 and ARM64 programs on 16K pages, and no i386.
- Per-game rules for games Steam starts itself (`SPEC.md` section 8.2). The `proton` launcher itself runs: see `docs/macos/M2-STATUS.md`.
- Native make rules in place of the wrapped scripts.

Packaging needs a macOS 15 SDK (`make MACOS15_SDK=<path>/MacOSX15.x.sdk`); Xcode only carries the current one.
