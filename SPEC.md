# Proton for arm64 macOS: specification

Status: draft 2, 2026-11-10. Working name: **Proton-macOS** (naming is an open decision, §17).

## 1. Summary

Port Valve's Proton (`ValveSoftware/Proton`, branch `proton_11.0`) to Apple Silicon macOS as a native arm64 distribution. Wine is **MetalSharp Wine** (Wine 11.20, native arm64 Mach-O). x86 Windows code runs through **MetalSharp's FEX fork** inside Wine: x86_64 through ARM64EC (`libarm64ecfex.dll`), i386 through WoW64 (`libwow64fex.dll`). There is no Rosetta and no hardware TSO.

The port is smaller than "x86 Linux to arm64 macOS" suggests, for two reasons:

- **Proton already has an arm64 target.** `TARGET_ARCH=arm64` builds an aarch64 Wine with ARM64EC and FEX for Linux. This project retargets that lane from `aarch64-linux-gnu` to `arm64-apple-darwin`. It does not invent an architecture story.
- **MetalSharp Wine already solves the macOS problems.** x18/TEB, the 4 GB PAGEZERO, 16K pages, W^X, ID registers, signing and the i386 entitlement are done and tested.

What is left is everything that makes Proton more than Wine: Valve's Wine patches, the `proton` launcher and prefix manager, the per-game compatibility tables, the media stack, the build system and the distribution format.

## 2. Verified starting point

Read on 2026-11-10 from a shallow clone of `proton_11.0` (commit `1f089f56`) and from the local MetalSharp trees.

| Fact | Source |
|---|---|
| Proton's default branch is `proton_11.0`. It has `TARGET_ARCH=arm64`, a `FEX` submodule pinned at FEX-2607, `toolmanifest_arm64.vdf`, `FEX_Config.json` and a `default_pfx_arm64` | `Makefile.in`, `.gitmodules`, repo tree |
| The arm64 lane builds `aarch64-unix`, `aarch64-windows`, `arm64ec-windows`, `i386-windows` and `x86_64-windows`. FEX is built as PE for `aarch64` and `arm64ec`, plus a unix library | `Makefile.in` lines 73-86 and the FEX section |
| The build runs inside a SteamRT 4 Linux container (`steamrt4/sdk/arm64-llvm`) and uses GNU tools throughout (`objcopy --add-gnu-debuglink`, `find -printf`, `*-linux-gnu-` cross prefixes) | `configure.sh`, `make/rules-common.mk` |
| The `proton` script picks the arm64 lane when `platform.machine() == 'aarch64'` and `files/bin-arm64/` exists. It writes a per-prefix FEX config from `STEAM_FEX_TSOENABLED`, `STEAM_FEX_MULTIBLOCK`, `STEAM_COMPAT_FEX_CONFIG` and a per-appid profile table | `proton` lines 574-581, 1502-1508, 1684-1721, 2075-2087 |
| `lsteamclient/unixlib.cpp` still has an `__APPLE__` branch that loads `steamclient.dylib` | `lsteamclient/unixlib.cpp:750` |
| Valve's Wine fork carries 1,454 commits on top of `wine-11.0`, linear, with no merges. 341 are already in `wine-11.20` | `ledger/wine.tsv` |
| MetalSharp Wine is Wine 11.20 plus 138 patches, with FEX-2610 plus 34 patches, built as native arm64 with PE archs `arm64ec`, `aarch64`, `i386`. x86_64 programs are served by ARM64X hybrids | `MetalSharp-Wine-publish` `README.md`, `docs/STATUS.md`, `patches/` |
| MetalSharp Wine already includes Mullion (D3D10/11/12 on Metal), DXVK-MacOS, VKD3D-Proton-MacOS, MoltenVK 1.4.3, WineMetalGL, FFmpeg 8.0, GStreamer 1.26, msync, Wine Mono and Gecko | same |
| i386 and 4K pages need the signed app: `com.apple.developer.cross-architecture-support`, macOS 26.4 or later, and a provisioning profile embedded in the loader's own bundle. Unsigned builds run x86_64 and ARM64 only, on 16K pages | `docs/STATUS.md` |
| Steam is the **Windows** client installed inside the prefix. Native macOS Steam is not installed | user, and `/Volumes/AverySSD/SteamLibrary` |

Build host: Apple M6, macOS 27.2, 16K pages. `xcode-select` currently points at the Command Line Tools, so `xcodebuild` and `actool` are unavailable until it points at Xcode.

## 3. Goals and non-goals

**Goals**

1. A fork of `ValveSoftware/Proton` that builds on an Apple Silicon Mac with one command and produces a signed, relocatable distribution.
2. The Proton contract holds: the `proton` verbs, the `STEAM_COMPAT_*` and `PROTON_*` environment variables, prefix versioning and upgrade, and the per-appid compatibility behaviour.
3. Every Valve Wine patch has a recorded disposition, and the ones that apply on macOS are in the Wine tree.
4. Games launched by Windows Steam inside the prefix get the same per-app treatment as games launched through the `proton` command.
5. Following upstream stays mechanical: a new Proton tag is a rebase plus a ledger update, not a new port.
6. Games that support EasyAntiCheat or BattlEye under Proton can run with anti-cheat active, so their online modes work (§9). This is a primary reason for the project, and the least certain part of it.

**Non-goals**

- Rosetta, hardware TSO, or any x86_64 Mach-O in the distribution.
- Native macOS Steam, `compatibilitytools.d` registration and `steamclient.dylib`. macOS Steam has no compatibility-tool support.
- SteamVR and OpenXR (`vrclient_x64`, `wineopenxr`, `openvr`, `OpenXR-SDK`). There is no SteamVR runtime on macOS.
- Kernel-mode anti-cheat (Vanguard and similar), and games whose developer has not enabled EasyAntiCheat or BattlEye for Proton. Neither can be made to work from the client side. Proton-enabled EasyAntiCheat and BattlEye are a goal (§9).
- Linux-only desktop integration: gamescope, the X11 fullscreen hack, Wayland, pressure-vessel, hidraw.
- Intel Macs.

## 4. Architecture

```
MetalSharp launcher ──┐                        ┌── per-app rules (appcompat DB)
                      ▼                        ▼
              proton (Python CLI) ──► wine loader (arm64 Mach-O, signed inner bundle)
                 prefix manager          ntdll.so / wineserver / win32u / winemac.drv
                 session env             │
                                         ├── ARM64 PE      native
                                         ├── x86_64 PE     FEX ARM64EC   (libarm64ecfex.dll)
                                         └── i386 PE       FEX WoW64     (libwow64fex.dll)
                                         │
              Windows Steam ─► game.exe  ├── D3D10/11/12   Mullion ─► Metal        (default)
              (same prefix)              ├── D3D9/10/11    DXVK-MacOS ─► MoltenVK  (opt-in)
                                         ├── D3D12         VKD3D-Proton-MacOS ─► MoltenVK (opt-in)
                                         ├── OpenGL        WineMetalGL ─► Metal
                                         └── media         winegstreamer ─► GStreamer/FFmpeg/VideoToolbox
```

Three layers, each owned by one tree:

| Layer | Owner | Role here |
|---|---|---|
| CPU, loader, kernel interface | MetalSharp Wine, MetalSharp FEX | Used as is. This project adds Wine patches, never forks the macOS enablement |
| Graphics | Mullion, DXVK-MacOS, VKD3D-Proton-MacOS, MoltenVK, WineMetalGL | Used as is. Proton's graphics switches are mapped onto MetalSharp's lanes |
| Proton | this repository | Build system, launcher, prefix manager, per-app rules, ported Valve Wine patches, media, fonts, packaging |

## 5. Repository

A fork of `ValveSoftware/Proton` with full history, on a branch named after its upstream (`proton_11.0-macos`). Upstream files are edited in place rather than copied, so `git rebase` and `git range-diff` against Valve's branch keep working.

Submodule changes:

| Path | Upstream | Here |
|---|---|---|
| `wine` | `ValveSoftware/wine` `proton_11.0` | `metalsharp/MetalSharp-Wine` branch `proton-macos`: `source/wine` plus the ported Valve patches (§6) |
| `FEX` | `FEX-Emu/FEX` at FEX-2607 | MetalSharp's fork, `source/fex` (FEX-2610 plus 34 patches) |
| `dxvk` | `doitsujin/dxvk` | `metalsharp/DXVK-MacOS` |
| `vkd3d-proton` | `HansKristian-Work/vkd3d-proton` | `metalsharp/VKD3D-Proton-MacOS` (also provides MoltenVK) |
| `mullion`, `winemetalgl`, `wfdxcompat` | none | new submodules, as in MetalSharp Wine |
| `dxvk-nvapi` | `jp7677/dxvk-nvapi` | dropped: each MetalSharp lane has its own NVAPI and NGX on MetalFX |
| `openvr`, `OpenXR-SDK`, `Vulkan-Loader` | as upstream | not initialised on darwin |
| `gstreamer`, `gst-orc`, `gst-libav`, `gst-plugins-rs`, `ffmpeg`, `dav1d`, `graphene`, `libsoup`, `glslang`, `vkd3d`, `Vulkan-Headers`, `SPIRV-Headers`, fonts | as upstream | kept at Proton's pins where they build for darwin; where MetalSharp Wine pins a newer version (FFmpeg 8.0, GStreamer 1.26), the newer one wins and the difference is recorded |
| `piper`, `vosk-api`, `kaldi`, `openfst` | as upstream | deferred to M6 (speech synthesis and recognition; `AVSpeechSynthesizer` may replace piper) |

New top-level directories: `darwin/` (build rules, signing, packaging, launcher glue), `appcompat/` (the rule extractor and generated database), `ledger/` (§6), `tests/`.

## 6. Wine: porting Valve's patches

Base stays **Wine 11.20 with MetalSharp's 138 patches**. Valve's fork is based on 11.0, so its patches are forward-ported, never the other way round.

Every commit in `wine-11.0..ValveSoftware/wine@proton_11.0` gets one row in `ledger/wine.tsv` (commit, subject, files, class, disposition, target commit, note). Classes:

| Class | What | Disposition |
|---|---|---|
| U | Already in upstream Wine by 11.20 (matched by patch-id, then by subject) | drop |
| W | Windows-side behaviour: game fixes, API stubs, loader and heap quirks, `WINE_*` knobs the `proton` script sets (`WINE_LARGE_ADDRESS_AWARE`, `WINE_HEAP_DELAY_FREE`, `WINE_HEAP_ZERO_MEMORY`, `WINE_HEAP_TOP_DOWN`, `WINE_CPU_TOPOLOGY`, `WINE_HIDE_*_GPU`, `WINE_MONO_*`, ...) | port |
| S | Steam integration: `SteamGameId` checks inside Wine, steamclient loading hooks, `steam.exe` awareness | port, adapted to Windows Steam (§8) |
| M | Media: winegstreamer, mfplat, quartz, mediaconv | port (§11) |
| G | Graphics glue: winevulkan, win32u, wined3d, dxgi interop for DXVK and vkd3d-proton | port where a MetalSharp lane uses it; otherwise drop |
| L | Linux-only: fsync and ntsync, winex11 and winewayland, the fullscreen hack, gamescope, hidraw, PulseAudio and ALSA, pressure-vessel, `/proc` and `/sys` readers | drop, or map to the macOS equivalent below |
| I | Input: winebus, SDL, Steam Input virtual gamepads | port the bus-independent parts; SDL and IOHID replace hidraw |
| C | Conflicts with a MetalSharp patch touching the same code | resolve by hand; MetalSharp's macOS behaviour wins, Valve's Windows-visible behaviour is kept |

macOS equivalents for class L:

| Proton on Linux | Here |
|---|---|
| fsync / ntsync (`WINEFSYNC`, `PROTON_NO_FSYNC`) | msync, on by default. `PROTON_NO_FSYNC=1` sets `WINEMSYNC=0` |
| winex11 fullscreen hack, `PROTON_LIMIT_RESOLUTIONS` | winemac.drv display-mode emulation and MetalFX display scaling; the mode-list limit is ported to winemac.drv |
| gamescope integration | none |
| `LD_LIBRARY_PATH` library discovery | relocatable `@rpath` / `@loader_path` install names; no `DYLD_*` variables |

Order of work: U is automatic. Then S and the `WINE_*` knobs (the launcher depends on them), then W in file-count order, then M, I, G. Each wave ends with the Wine conformance run MetalSharp already has (`scripts/run-winetest.sh`), on ARM64, x86_64 and i386, compared against the pre-wave baseline.

Ported commits keep Valve's author and message, with a trailer naming the upstream commit, so the ledger can be regenerated from the tree.

## 7. FEX

Use MetalSharp's fork unchanged. It is newer than Proton's pin (FEX-2610 against FEX-2607). The work is adopting Proton's configuration contract:

- Ship Proton's `FEX_Config.json` as `share/fex-emu/Config.json`, with MetalSharp's defaults where they differ on purpose. Both already agree on `TSOEnabled=1` and `X87ReducedPrecision=1`.
- The launcher writes `proton-fex-config.json` per prefix and sets `FEX_APP_CONFIG` and `FEX_APP_CONFIG_LOCATION`, exactly as upstream does.
- `STEAM_FEX_TSOENABLED`, `STEAM_FEX_MULTIBLOCK`, `STEAM_COMPAT_FEX_CONFIG` and `fex_application_profiles` keep working.
- Precedence, lowest to highest: MetalSharp's built-in ntdll defaults, `Config.json`, the per-app profile, `FEX_*` variables set by the user.

Checked in M0 by reading the source: both Windows frontends load their configuration through code that reads `FEX_APP_CONFIG` and `FEX_APP_CONFIG_LOCATION`. Still to test at run time: how that interacts with the defaults Wine patches 0063, 0066-0068, 0073 and 0078 set from ntdll.

## 8. Steam integration

Steam is the Windows client, running inside the prefix under FEX. Games are its child processes in the same prefix. That changes three things compared with Proton on Linux.

**8.1 No client bridge.** Games load Valve's real `steamclient64.dll` and talk to the real Steam process. `lsteamclient`, Proton's stub `steam.exe`, and the `legacycompat` DLL copying are not built or installed on darwin. The `__APPLE__` branch in `lsteamclient` and WineForge's native bridge stay in the tree, unbuilt, in case native macOS Steam ever becomes useful.

**8.2 The launcher does not sit in front of each game.** On Linux, Steam runs `proton waitforexitandrun game.exe` per launch, and the script applies the per-app logic. Here Steam calls `CreateProcess` itself. So the per-app logic moves to process start:

- `appcompat/extract.py` writes `share/proton/appcompat.env` from the `proton` script. It does not parse the script: it loads it as a module, runs its session set-up once per app id it names, and records what differs from an unknown app. The tables stay in the script, in upstream's format, so rebases don't conflict; the database is a build product, in the format of `.metalsharp/launch.env` with one section per app id.
- The Wine unix side resolves the app id once per process, from `SteamAppId` / `SteamGameId` in the environment, and otherwise from the `appmanifest_*.acf` whose `installdir` contains the executable. It then applies the matching rules through the mechanism that already applies `.metalsharp/launch.env` (Wine patches 0080, 0119).
- The `proton` command uses the same database, so both entry points behave the same.
- Precedence, lowest to highest: appcompat database, `.metalsharp/launch.env`, `.metalsharp/launch.local.env`, variables the user set explicitly.

Checked in M0: MetalSharp Wine patch 0127 already reads `SteamAppId` on the unix side to recognise a game Steam started, and ships that way. A direct trace of one Steam-launched game's environment is still to be done.

**8.3 One shared prefix for Steam games.** Proton's one-prefix-per-app model can't apply to games Steam launches. The Steam prefix is created, versioned and upgraded by the launcher when the Steam session starts. Games started through the `proton` command (GOG, Epic, standalone) get their own prefix under `STEAM_COMPAT_DATA_PATH`, as upstream.

Consequences to handle: prefix upgrades run while no game is running (the launcher takes Proton's prefix lock and waits for `wineserver -w`); per-app prefix hacks in `upgrade_pfx` and `setup_prefix` that assume a private prefix are reviewed one by one and either made global, moved to the appcompat database, or dropped.

## 9. Anti-cheat

### 9.1 How Proton does it on Linux

Verified in `Makefile.in` and in `ValveSoftware/wine@proton_11.0`:

- The anti-cheat itself is the vendor's **native Linux module**, not the Windows one. The game developer opts in: for EasyAntiCheat by shipping `easyanticheat_x64.so` next to the Windows `easyanticheat_x64.dll`, for BattlEye through BattlEye's own runtime.
- A **bridge** stands in for the Windows module. Wine loads it as a builtin (`easyanticheat_x64.dll` plus a unix library) and it forwards to the Linux module. The bridges are built from `eac-bridge/` and `battleye-bridge/`, which are **not in the public repository**; `Makefile.in` only builds them when those directories exist, and only for x86_64 and i386. The built bridges reach users as Steam tools ("Proton EasyAntiCheat Runtime", "Proton BattlEye Runtime").
- The Wine side is public and small:
  - `ntdll/unix/loader.c`: `PROTON_EAC_RUNTIME` and `PROTON_BATTLEYE_RUNTIME` add the runtimes' directories to the DLL path.
  - `ntdll/unix/loadorder.c`: the EAC bridge is used only when the Linux module sits next to the Windows one; the EAC launcher process always gets the native DLL.
  - `kernelbase/process.c`: a "BattlEye Launcher" is redirected to the builtin `belauncher.exe`; an "EasyAntiCheat Launcher" child gets `PROTON_EAC_LAUNCHER_PROCESS`.
  - `programs/belauncher`, a DNS exception in `ws2_32`, and an exact instruction sequence in the x86_64 exception dispatcher that "some anticheats need".

Found in the local Elden Ring install: the Windows depot ships `Game/eossdk-win64-shipping.so`. It is an **aarch64 Linux** ELF (soname `libEOSSDK-LinuxArm64-Shipping.so`, needs glibc), it contains the `EOS_AntiCheatClient_*` interface, and it reads `/proc/self/maps`, `/proc/self/exe` and `/etc/machine-id`. The Windows `eossdk-win64-shipping.dll` contains `wine_get_version`. So Epic already ships an arm64 Linux anti-cheat path for arm64 Proton, in the files Windows Steam downloads. It has no direct system-call instructions, uses only baseline glibc 2.17 symbols (410 imports), and its segments are aligned to 64K. Valve's Wine does not load it by name, so the loader is the EasyAntiCheat runtime bridge or Epic's own DLL; which one is still open (`docs/macos/M0-AC0-FINDINGS.md`).

Also found: in that install `start_protected_game.exe` is a copy of `eldenring.exe` and the real launcher is `start_protected_game.old`. Elden Ring currently runs with EasyAntiCheat off, which means offline only. Turning that into online play is the concrete first target.

AC0 added two things (`docs/macos/M0-AC0-FINDINGS.md`). Valve's bridges are thin: each unix half is an 18 KB library that opens the vendor's Linux module and forwards calls. And Elden Ring's genuine EAC launcher is Wine-aware by itself: its strings show it reading `/proc/<pid>/maps`, looking for `libc.so` and naming Linux platforms. The reading, not yet observed running, is that Epic's Windows code finds the host's libc in the process and calls Linux directly, so for Elden Ring the path is mostly Epic's code and not Valve's bridge.

### 9.2 The problem on macOS

Every piece that does the actual checking is a Linux ELF library: x86_64 for most games and for Valve's bridges, aarch64 for the newer Epic path. An arm64 Mach-O process can't `dlopen` either. Three things are needed that Proton on Linux gets for free: something to load ELF, something to answer glibc and Linux system calls, and for x86_64 something to execute the code.

The Windows anti-cheat can't be the answer. It needs its kernel driver.

### 9.3 Design: a Linux module host inside Wine

A new component, `darwin/linuxhost/`, lets a Wine process load and run Linux shared libraries.

| Part | What it does |
|---|---|
| ELF loader | Maps segments, applies relocations, sets up TLS, runs constructors. aarch64 Linux libraries align segments to 64K, which fits 16K pages |
| glibc layer | The symbols the modules import from `libc.so.6`, `libm`, `libdl`, `libpthread` and `libgcc_s`, with Linux structure layouts, constants and `errno` values, implemented on libSystem. Built as Linux-ABI ELF objects itself, so variadic calls follow the Linux convention, with a narrow fixed-argument gate into Mach-O code |
| Linux system-call layer | Translates the calls the modules make directly. Starts from an observed list and grows |
| Linux view of the process | `/proc/self/maps`, `/proc/self/exe`, `/proc/self/status`, `/etc/machine-id`, `uname`, the auxiliary vector and a vDSO, generated from the real process: Mach VM regions, Wine's module list, the real executable |

Two execution engines, one per module architecture:

- **x86_64 modules through FEX.** FEX is already in the process and translates any x86_64 code, whatever container it came from. The module runs on the guest side, like a DLL with a different calling convention. Two FEX changes: treat registered ELF ranges as x86 code, and send a `syscall` executed inside those ranges to the Linux layer instead of the NT one. Because FEX sees every instruction, direct system calls are caught without touching the module's code. This is the cleaner engine.
- **aarch64 modules natively.** Same CPU, no translation. The hard part is direct system calls: Linux uses `svc #0` with the number in x8, which macOS would misread, and macOS offers no user-space trap for it. Rewriting the instructions would break a module that checksums itself. The candidate that leaves the code untouched is to run the module's code in a Hypervisor.framework guest that shares the process's memory and traps `svc` to the host. That is a large piece of work with open questions (guest address size against a 47-bit process, per-thread vCPUs, cost per call), so it is built only if a module needs it. The one arm64 library inventoried so far, Elden Ring's Epic SDK, has no direct system calls and does not.

Other details: Linux code may use x18, so it runs only where Wine already tolerates that, with the TEB pointer saved around calls; Linux signal numbers and `sigaction` layouts are translated; threads the module creates become pthreads registered with Wine.

**As built in AC1 (`darwin/linuxhost/README.md`), two things differ from the table above.** The host is x86_64 Windows code that FEX runs, so the glibc layer sits on the Windows C runtime and there are no transitions to macOS code. And no FEX change is needed for system calls: FEX hands every `syscall` to Wine's ntdll, which now sends those from a registered library to the host.

### 9.4 Bridges

Valve's bridge sources are private, and the interface between a game and the EasyAntiCheat or BattlEye module is undocumented. Two ways to get a bridge:

1. **Run Valve's built bridges.** The launcher fetches the two Proton runtimes from Steam for the user's account; nothing is redistributed. The bridge's PE half runs under FEX like any DLL, and its unix half is an x86_64 ELF that the module host loads. Wine's unix-call dispatch gets one addition: a unix library that is a hosted ELF is called on the guest side. Recommended, because it keeps the project out of a proprietary interface.
2. **Write our own bridge.** Only if 1 fails, and only from observable behaviour.

The public Wine pieces in 9.1 are ported as ledger class S. The launcher sets `PROTON_EAC_RUNTIME` and `PROTON_BATTLEYE_RUNTIME`. Since Windows Steam does not install Linux tools, the launcher downloads and updates the two runtimes itself; they are apps 1826330 (EasyAntiCheat) and 1161040 (BattlEye), which need a signed-in Steam account. Their licence terms are not stated in the downloads.

The BattlEye runtime also contains BattlEye's own client module (`BEClient_x64.so`). It rewrites its own code and makes direct system calls, so it runs only on the FEX engine.

For launchers that find libc themselves, as Elden Ring's appears to, the host must also show the Linux view through Wine's file layer and keep a real x86_64 ELF `libc.so` image in the process for them to resolve and call.

### 9.5 What can and can't work

| Kind of game | Outcome |
|---|---|
| No client anti-cheat, or VAC | Already works |
| EasyAntiCheat or BattlEye, developer enabled Proton | The target. Elden Ring is the first test |
| EasyAntiCheat or BattlEye, developer did not enable Proton | Cannot work. The service refuses the client; nothing local changes that |
| Kernel-mode anti-cheat | Cannot work |

### 9.6 Rules

These are requirements, not preferences. A layer that deceives an anti-cheat gets blocklisted, and the people who pay are users whose accounts are banned.

- The vendor's modules run **unmodified**. No patching, no hooking of their code, no altering what they compute.
- The Linux view is generated from the real process. Nothing is hidden from it: no filtered module lists, no concealed debuggers or tools, no forged integrity results. The layer answers as a Linux ABI because that is what a Linux ABI layer is; it does not otherwise pretend.
- Anti-cheat is **off by default and opt-in per game**, with a plain warning that it is unofficial and that an account ban is possible. Until a vendor says otherwise, that warning stays.
- Contact Epic (EasyAntiCheat) and BattlEye before any public release with this enabled, describe exactly what the layer does, and ask how they want it identified. If a vendor says no, that vendor's support is not shipped.

### 9.7 Staging and stop conditions

| | Work | Outcome that decides the next step |
|---|---|---|
| AC0 | Inventory. Fetch both runtimes and list their files, architectures and imports. Find what loads `eossdk-win64-shipping.so` in Proton's arm64 lane. Record every glibc import and every direct system call of the bridges and of Elden Ring's modules, by running them on Linux under `strace` | A fixed list of what the host must implement. If the arm64 Linux lane has no working anti-cheat upstream either, the aarch64 engine is dropped and only x86_64 is pursued |
| AC1 | ELF loader, glibc layer, x86_64 engine through FEX. Test with ordinary Linux libraries first, then the EAC bridge | The bridge loads and initialises |
| AC2 | Elden Ring with its real `start_protected_game.exe` on a throwaway account | The session starts and stays connected, or we learn exactly what the module or service rejects |
| AC3 | BattlEye, a second EAC title, the aarch64 engine if AC0 kept it, the opt-in UI, vendor contact | Ready to ship behind the opt-in |

This can fail in ways no amount of engineering here fixes. The module that does the real checking is downloaded at run time, is obfuscated and changes without notice. It can notice that the kernel underneath is not Linux through behaviour the host does not reproduce exactly. The service can decide to reject the client. AC2 is where that is found out, on one game, before the rest of the work is spent. If AC2 ends in a rejection that only deception would get past, the anti-cheat track stops there, per 9.6.

## 10. The `proton` launcher

Keep it in Python, edited in place, so it rebases. Ship a pinned, relocatable arm64 Python inside the distribution; macOS has no system Python outside the developer tools.

Unchanged contract: verbs `run`, `waitforexitandrun`, `runinprefix`, `destroyprefix`, `getcompatpath`, `getnativepath`; `STEAM_COMPAT_DATA_PATH`, `STEAM_COMPAT_CLIENT_INSTALL_PATH`, `STEAM_COMPAT_CONFIG`, `STEAM_COMPAT_APP_ID`; `user_settings.py`; `PROTON_LOG` and `PROTON_LOG_DIR`; the `version` file, tracked files and prefix upgrade.

One new verb: `steam`, which prepares the Steam prefix and starts `steam.exe`. The MetalSharp launcher calls it.

Changes, all behind `sys.platform == 'darwin'`:

| Upstream | Darwin |
|---|---|
| `platform.machine() == 'aarch64'` | also accept `arm64` |
| `files/bin-arm64/`, `default_pfx_arm64/` | the only lane; the wine binary is the loader inside the signed inner bundle |
| `LD_LIBRARY_PATH`, `ORIG_LD_LIBRARY_PATH` | not set |
| `lib/{x86_64,aarch64,i386}-linux-gnu`, `GST_PLUGIN_SYSTEM_PATH_1_0` | MetalSharp's layout; the bundle's GStreamer path |
| `copy_file_range` / reflink | `clonefile(2)` through ctypes on APFS, plain copy elsewhere |
| ext4 casefold `ioctl` | skipped |
| `/proc/modules` NVIDIA probe, `libGLX_nvidia` lookup, `NVIDIA_WINE_DLL_DIR` | constant "no NVIDIA driver" |
| `/proc/sys/vm/max_map_count` warning | skipped |
| `steam-runtime-launcher-interface-0` | skipped |
| `wine-preloader` direct exec | not applicable |
| `c:\windows\system32\steam.exe` wrapper | the game executable directly |
| copying DXVK, vkd3d-proton and nvapi DLLs into the prefix | not done: ntdll routes Direct3D modules to the selected lane |
| `uname` in the log header | plus macOS version, page size, entitlement state, graphics lane |

Environment mapping:

| Proton | Here |
|---|---|
| default (DXVK and vkd3d-proton) | Mullion |
| `PROTON_USE_WINED3D`, `PROTON_USE_WINED3D11` | `GRAPHICS_BACKEND=wine` |
| new: `PROTON_USE_DXVK=1` | `GRAPHICS_BACKEND=dxvk` |
| new: `PROTON_USE_VKD3D=1` | `GRAPHICS_BACKEND=vkd3d` |
| `PROTON_DXVK_D3D8` | `GRAPHICS_BACKEND=dxvk` with its D3D8 |
| `PROTON_NO_D3D10`, `PROTON_NO_D3D11` | DLL overrides, as upstream |
| `PROTON_NO_FSYNC` | `WINEMSYNC=0` |
| `PROTON_DISABLE_NVAPI`, `PROTON_FORCE_NVAPI`, `PROTON_HIDE_NVIDIA_GPU` | the lane's NVAPI and the GPU identity in `winemac.conf` |
| `PROTON_USE_WOW64`, `PROTON_USE_ARM64` | ignored: there is one lane |
| `PROTON_USE_XALIA` | off until xalia is validated on winemac.drv |
| the `WINE_*` knobs | passed through; they depend on §6 class W |

## 11. Media

MetalSharp Wine already bundles FFmpeg 8.0 (with VideoToolbox and AudioToolbox) and GStreamer 1.26. This project adds:

- Valve's winegstreamer, mfplat and quartz patches (class M).
- `gst-libav` and the dav1d plugin from `gst-plugins-rs`, built for `arm64-apple-darwin`.
- `share/media/blank.{mkv,mka,ptna}`.

Proton's transcoded-media path (`MEDIACONV_*`, the `.foz` files) depends on the Linux Steam client downloading pre-transcoded media. Windows Steam doesn't, so those variables stay unset and decoding goes straight to FFmpeg and VideoToolbox. Hardware decode for H.264, HEVC and AV1 is the default where VideoToolbox offers it.

## 12. Build system

Proton's `Makefile.in` remains the orchestrator. Darwin support is added to it rather than written beside it.

- New variable `TARGET_OS` (`linux` default, `darwin`). `configure.sh --target-arch=arm64 --target-os=darwin` skips the container and writes a host Makefile.
- `make/rules-common.mk`: `aarch64-unix_TARGET := arm64-apple-darwin` with Xcode's clang; PE targets through llvm-mingw, using MetalSharp's `toolchain/mingw-shims` so llvm tools win over Homebrew's GNU ones; `install-strip` uses `strip -S` and `dsymutil` for Mach-O and `llvm-objcopy` for PE; `find -printf` is replaced by a portable form.
- Requirements: Xcode with the Metal toolchain, GNU make 4, bash 5, cmake, ninja, meson, pkgconf, autoconf, automake, libtool, bison, flex, nasm, gettext, gperf, rsync, fontforge, a Rust toolchain. `darwin/check-host.sh` verifies them and prints what is missing.
- MetalSharp Wine's scripts are the reference for each darwin rule: dependencies (`build-deps.sh`), ARM64X runtimes (`build-arm64ec-runtimes.sh`), Wine (`build-wine.sh`, including `-platform_version macos 15.0 12.0` on the loader and 64K section alignment), FEX (`build-fex.sh`: no LTO, generic armv8 tuning), Mullion, WineMetalGL, DXVK-MacOS, VKD3D-Proton-MacOS and MoltenVK staging. Each becomes a `rules-*` invocation or a darwin rule file under `darwin/make/`.
- PE architectures: `arm64ec`, `aarch64`, `i386`. A separate `x86_64-windows` build is not made; ARM64X hybrids cover it. Proton's arm64 lane does build one, so anything that needs a pure x86_64 PE is found during M1 and listed.
- `default_pfx.py` builds one default prefix with the built Wine, and relative symlinks into `lib/wine/aarch64-windows`.
- Minimum deployment target macOS 15.0. The Mach-O audit from MetalSharp (`audit-macho.sh`: arm64 only, no foreign paths) is a build step.

Targets: `make dist`, `make redist`, `make module=<dll> module`, `make sign`, `make notarize`, `make test`.

## 13. Distribution

```
Proton-macOS.app/Contents/
  MacOS/proton                      launcher stub, starts the bundled Python
  Resources/
    proton, filelock.py, user_settings.sample.py, version, LICENSE*
    files/
      bin/                          wine, wineserver, msidb, innoextract, cabextract
      lib/wine/aarch64-unix/        Wine unix side, wine.app (inner loader bundle with the profile)
      lib/wine/{aarch64,i386}-windows/
      lib/{mullion,dxvk,vkd3d-proton,winemetalgl,wfdxcompat}/
      share/default_pfx/  share/fex-emu/Config.json  share/proton/appcompat.toml
      share/fonts/  share/media/  share/wine/  share/licenses/
```

- Signed with Developer ID, hardened runtime, notarized and stapled. Entitlements as MetalSharp Wine: cross-architecture support, allow-jit, allow-unsigned-executable-memory, disable-executable-page-protection, disable-library-validation.
- A second artifact, a relocatable `.tar.xz`, is ad-hoc signed: x86_64 and ARM64 programs only, 16K pages. This is what a contributor without the entitlement can build and run.
- `toolmanifest_*.vdf` and `compatibilitytool.vdf` are not produced on darwin.

## 14. Testing and acceptance

| Area | Test | Pass |
|---|---|---|
| Wine | MetalSharp's conformance runs on ARM64, x86_64, i386 | no regression against the MetalSharp Wine 6.0 baseline after each ledger wave |
| FEX | MetalSharp's benchmarks and checksum tests | checksums identical to native ARM64 |
| Launcher | new `tests/proton/`: every verb, path conversion both ways, prefix creation, upgrade from an older `version`, tracked-file removal, locking under two concurrent launches | all pass on a clean machine |
| Appcompat | golden test: the generated database reproduces what the upstream script would set for every app id it names | exact match |
| Process-start rules | a test executable started by a stub parent with `SteamAppId` set, and one resolved through an `appmanifest` | the environment it sees matches the database |
| Media | Media Foundation and quartz playback smoke tests: H.264, HEVC, AV1, WMV, AAC | frames and audio decoded |
| Build | clean-machine build from `git clone --recurse-submodules` | `make dist` succeeds; Mach-O audit clean |
| Games | a fixed matrix from the installed library, covering each lane and each guest architecture, for example ELDEN RING, The Witcher 3, God of War Ragnarök, Red Dead Redemption 2, Portal 2, Celeste, Hollow Knight: Silksong, DOOM (2016), Crusader Kings II, Ori and the Blind Forest | launches from Steam, reaches gameplay, no regression against MetalSharp Wine 6.0 |

## 15. Milestones

| | Deliverable | Done when |
|---|---|---|
| M0 | Fork, submodules repointed, `ledger/wine.tsv` generated with classes U and L filled automatically, the three M0 verifications (§7, §8.2, PE archs) answered | the ledger covers every Valve commit; open questions closed |
| M1 | Darwin build: `make dist` produces MetalSharp Wine's contents through Proton's Makefile | the conformance baseline matches MetalSharp Wine 6.0 |
| M2 | Launcher on darwin: all verbs, prefix manager, FEX config, environment mapping, `steam` verb | launcher tests pass; Steam starts and a game runs through `proton steam` |
| M3 | Appcompat extractor and process-start rules | golden and process-start tests pass |
| M4 | Wine ledger waves: S and knobs, then W, I, G | every row has a final disposition; conformance holds |
| M5 | Media | media tests pass |
| M6 | Signing, notarization, release artifacts, fonts parity, speech (piper/vosk or replacements), rebase automation for new upstream tags | a tagged release; a dry-run rebase onto the next Proton tag documented |

M1 and M2 don't depend on M4. M3 depends on M2. M4 is the long pole and can run in parallel from M0 on.

The anti-cheat track (AC0 to AC3, §9.7) runs beside these. AC0 needs nothing and starts with M0. AC1 needs M1. AC2 needs M2 and the class S Wine pieces from M4. Because AC2 decides whether the track continues, it is scheduled as early as those allow.

## 16. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| The entitlement is tied to a bundle ID and provisioning profile | a new app needs Apple to grant the entitlement again; without it, no i386 and no 4K pages | decision 1 below |
| 1,036 Valve commits to review and forward-port across 20 Wine releases | conflicts, subtle regressions | the ledger, wave-by-wave conformance runs, upstream-first matching to shrink the set |
| Shared Steam prefix | a per-app hack leaks to other games; upgrades race running games | §8.3 review; upgrade only at session start under the lock |
| Per-app rules depend on identifying the app at process start | wrong or missing rules | two resolution paths (environment, appmanifest), and a log line naming the app id and rules applied |
| Upstream moves weekly | drift | edit in place, generated database, ledger keyed by upstream commit |
| Steam's own client (CEF) under FEX | slow or unstable UI | already handled by MetalSharp's launcher patches; tracked in the game matrix |
| Anti-cheat modules reject the environment, or the vendor objects | the main motivating feature does not ship | one-game spike (AC2) before the bulk of the work; the rules in §9.6; vendor contact before release |
| Anti-cheat modules change without notice | support breaks after a game update | the system-call and glibc layers log every unimplemented call with the module that made it; a per-game off switch |
| Licences and name | "Proton" is Valve's mark; MetalSharp's own glue is AGPL-3.0, Proton's is BSD-3-Clause | decision 2; keep each component's licence in `share/licenses/`, new files in this fork under Proton's licence unless decided otherwise |

## 17. Decisions needed

1. **Bundle identity.** Ship as its own app with a new bundle ID (needs its own provisioning profile with the cross-architecture entitlement), or build it as the next MetalSharp Wine bundle, reusing the existing App ID and profile. Recommendation: reuse the existing identity. It removes the only external dependency in the plan.
2. **Name.** "Proton" in the product name, or a MetalSharp name with "based on Proton". Recommendation: a MetalSharp name.
3. **Relationship to MetalSharp-Wine.** Whether this repository replaces `MetalSharp-Wine`'s build scripts as the way MetalSharp Wine is built, or stays a second distribution built from the same sources. Recommendation: second distribution until M4 is complete, then replace.
Decided:

- **Anti-cheat rules (2026-11-10).** §9.6 stands as written: modules unmodified, nothing hidden, opt-in with a ban warning, vendors contacted before release.
