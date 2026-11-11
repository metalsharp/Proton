# M1 status: the macOS build

2026-11-10. M1 is defined in `SPEC.md` §15: `make dist` produces MetalSharp Wine's contents through Proton's Makefile.

## Result

`make proton` on an Apple M6 (macOS 27.2, Xcode 27.3) builds `build/build-<branch>-local/dist/` with no container.

| Stage | Result |
|---|---|
| Dependencies | 22 libraries built from source into `deps/prefix` (about 20 minutes) |
| Wine | Wine 11.20 with MetalSharp's 139 commits (`702b230e88d`), native arm64, PE archs arm64ec, aarch64, i386 (about 60 minutes) |
| FEX | `libarm64ecfex.dll`, `libwow64fex.dll` and their unix libraries |
| Prefix payloads | Microsoft's shader compilers, the renamed Liberation fonts, Wine Mono 11.3.0, Wine Gecko 2.47.4 |
| Audit | Passes: arm64 only, minimum macOS 15.0, no paths into the build tree |
| `dist/` | Proton's layout: `proton`, `filelock.py`, `version`, licences, and the 2.5 GB relocatable Wine tree in `files/` |

## Checked by running it

- `wine --version` prints `wine-11.20 (MetalSharp Wine 6.0)`.
- A new prefix is created in 20 seconds, with the shader compilers and fonts in place.
- Native ARM64: `cmd /c ver` and the benchmark run.
- x86_64 through FEX: the benchmark runs, every checksum equals the native ARM64 run, and the memory-ordering test reports 0 violations.

| Benchmark | ARM64 native | x86_64 under FEX |
|---|---|---|
| int | 91.9 ms | 94.2 ms |
| fp | 4.3 ms | 7.7 ms |
| mem | 40.3 ms | 35.8 ms |
| atomic | 333.5 ms | 140.9 ms |
| order | 164.8 ms, 0 violations | 170.1 ms, 0 violations |

Single runs, for a sanity check only.

## Compared with MetalSharp Wine 6.0

Against the packaged `metalsharp-wine-6.0-arm64` tree, file lists under `lib/wine`:

| Directory | This build | 6.0 |
|---|---|---|
| `aarch64-unix` | 34 | 37 |
| `aarch64-windows` | 1011 | 1015 |
| `i386-windows` | 1097 | 1099 |

Nothing is in this build that 6.0 lacks. Everything 6.0 has and this build lacks is an add-on not built yet: WineMetalGL (`winemetalgl.*`, `libwinemetalgl.dylib`), Mullion (`winemetal.*`, `lib/mullion`), NVAPI and NGX (`nvapi64.dll`, `nvngx.dll`), `lib/dxvk`, `lib/vkd3d-proton`, `lib/wfdxcompat`, MoltenVK 1.4.3, innoextract and cabextract.

## Not done

- **The add-ons above.** Until they are built, Direct3D goes to Wine's own wined3d and OpenGL to Apple's.
- **Conformance run.** The Wine test suites have not been run against this build, so the M1 baseline comparison is still open.
- **Signing.** This build is ad-hoc signed: x86_64 and ARM64 only, 16K pages. i386 programs cannot start, which shows during prefix creation as two failed Mono helper programs (`removeuserinstalls-x86.exe`, `installinf-x86.exe`) and leaves Wine Mono uninstalled in the prefix.
- **Version string.** 6.0 reports `wine-11.20-139-g702b230e88d`; this build reports `wine-11.20`, because Wine is built in a copy of the submodule without its git data.
- **`make tests`** stops at one program (below).
- **The toolchain** is still cloned from an existing MetalSharp Wine tree.

## Problems found in MetalSharp Wine's build scripts

Each one breaks a fresh build of MetalSharp Wine itself. `darwin/make/darwin.mk` works around the first two.

1. **`build-fex.sh`: FEX fails to compile with current CMake.** The bundled fmt builds itself as a C++ module and CMake scans for modules; the scan cannot find headers with llvm-mingw. Fix: pass `-DFMT_MODULE=OFF -DCMAKE_CXX_SCAN_FOR_MODULES=OFF`. The existing build tree only works because its CMake cache already holds both.
2. **`build-deps.sh`: MoltenVK is installed universal**, and `audit-macho.sh` then rejects its x86_64 slice. Fix: thin it to arm64 when installing.
3. **`build-tests.sh`: `cpuident.c` does not link.** It calls `CallNtPowerInformation` and needs `-lpowrprof`.
4. **`wine.inf`: a missing shader compiler hangs prefix creation.** If `share/wine/shadercompilers` is absent, setupapi asks for the file forever at full CPU. The build should fail earlier, or the section should be optional.
