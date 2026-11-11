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

What builds, what was run and what is left is in `docs/macos/`: `M1-STATUS.md` (the build), `M2-STATUS.md` (the launcher), `M3-M4-AC1-STATUS.md` (per-game rules, Valve's Wine patches, the Linux module host), `M6-STATUS.md` (the app bundle), `CONFORMANCE.md` (Wine's test suite).

This build is MetalSharp Wine 7.0 (`wine --version` reports `MetalSharp Wine 7.0`): the `wine` submodule pins MetalSharp-Wine's `source/wine`, and `darwin/metalsharp-wine` pins its `main`, which carries the same Wine as patches 0141–0161.

`dist/files` has everything MetalSharp Wine 6.0 ships: Wine, FEX, Mullion, WineMetalGL, WFDXCompat, DXVK-MacOS, VKD3D-Proton-MacOS with MoltenVK 1.4.3, innoextract, cabextract, the files `wine.inf` installs into a prefix, and the MetalSharp app's payloads in `share/metalsharp`. Those payloads come from the seed tree's `install/share/metalsharp` for now, until MetalSharp's bundles are fetched here. On top of that it has Proton's launcher, the per-game rules database, `belauncher.exe`, and the Linux module host in `lib/linuxhost` (the `linuxhost` add-on, built from `darwin/linuxhost`), which Easy Anti-Cheat's EOS bootstrapper gets from ntdll.

To try a build in the MetalSharp app, put the signed `MetalSharp-Wine.app` in place of `~/.metalsharp/runtime/MetalSharp-Wine.app` (with MetalSharp and its games closed). The app's `wine` wrappers and the `host` link point into that bundle.

## Signing

`make app` builds the application bundle. Without arguments it is signed ad hoc, and runs x86_64 and ARM64 programs on 16K pages, with no i386. A Developer ID build has 4K pages, the low 4GB and i386:

```bash
make app SIGN_IDENTITY="Developer ID Application: <name> (<team>)" PROFILE=<path>/MetalSharp_Wine.provisionprofile
```

DLSS needs the NGX cores (`nvngx.dll`) signed with Mullion's NGX key: set `MULLION_NGX_SIGNING_KEY_FILE` (Mullion's core) and `NGX_SIGNING_KEY_FILE` (the VKD3D and DXVK lanes' core) to the PEM private key when building. Without it they are unsigned and games report DLSS as unsupported. The key is otherwise only in the Mullion and VKD3D-Proton-MacOS repositories' secrets, whose CI builds sign them.

The provisioning profile carries the cross-architecture entitlement for `com.metalsharp.wine`, so the bundle keeps that identifier. Run Windows programs through `Contents/MacOS/wine` in the bundle; the loose `dist/files` tree is not signed for them.

Not done yet:

- Notarization. A Developer ID build runs from the command line; Gatekeeper rejects it when opened from the Finder until it is notarized (`xcrun notarytool submit`, then `xcrun stapler staple`).
- Native make rules in place of the wrapped scripts, and building the llvm-mingw toolchain from nothing.

Packaging needs a macOS 15 SDK (`make MACOS15_SDK=<path>/MacOSX15.x.sdk`); Xcode only carries the current one.

## Tests

```bash
darwin/tests/launcher.sh <build dir>/dist
```

runs the launcher's verbs, the environment mapping, the FEX configuration, logging, concurrent launches and the per-game rules against a built `dist/`.
