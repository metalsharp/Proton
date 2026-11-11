# M0 and AC0 findings

2026-11-10. Milestones are defined in `SPEC.md` §15 and §9.7.

## M0

| Item | Result |
|---|---|
| Fork | Local repository on branch `proton_11.0-macos`, based on `ValveSoftware/Proton` `proton_11.0` at `1f089f56` (`proton-11.0-2e-2`). Remote `upstream`. GitHub fork: `metalsharp/Proton` (remote `origin`); the branch is not pushed |
| Submodules | `wine`, `FEX`, `dxvk`, `vkd3d-proton` repointed to the MetalSharp sources at the commits MetalSharp Wine 6.0 pins; `mullion`, `winemetalgl`, `wfdxcompat` added. Staged, not committed, and not checked out |
| Wine ledger | `ledger/wine.tsv`: 1,454 commits, 418 settled automatically. See `ledger/README.md` |
| FEX reads Proton's config variables (§7) | **Yes, by reading the source.** Both Windows frontends call `FEX::Config::LoadConfig` (`Source/Windows/ARM64EC/Module.cpp:707`, `WOW64/Module.cpp:508`), and that reads `FEX_APP_CONFIG` and `FEX_APP_CONFIG_LOCATION` (`Source/Common/Config.cpp:512`, `:664`). Not yet tested at run time, and the interaction with the defaults MetalSharp's ntdll sets is still to be checked |
| Windows Steam exports `SteamAppId` (§8.2) | **Supported by shipped behaviour.** MetalSharp Wine patch 0127 already reads `SteamAppId` on the unix side to recognise a game Steam started. A direct trace of a Steam-launched game's environment is still worth one run |
| Separate x86_64 PE build needed | Open; answered by the M1 build |

## AC0

Done here:

- **The Wine half of anti-cheat support is 17 commits**, marked `anticheat=yes` in the ledger. They cover the runtime DLL paths, the EasyAntiCheat load-order rule, the launcher detection, `belauncher.exe`, the DNS exception, a forced en-US locale for the EAC launcher, and passing some environment variables to the unix side when the EOS bootstrapper starts.
- **Wine does not load `eossdk-win64-shipping.so` by name.** Nothing in Valve's tree mentions it. It is loaded either by the EasyAntiCheat runtime bridge or by Epic's Windows SDK DLL, which contains `wine_get_version`. Valve also restored `__wine_unix_call()` "for compatibility" (`473509718c7`), which is the entry point such a caller would use.
- **Inventory of Elden Ring's `eossdk-win64-shipping.so`** (`ledger/anticheat/eossdk-linuxarm64.imports.tsv`):

| | |
|---|---|
| Architecture | aarch64, soname `libEOSSDK-LinuxArm64-Shipping.so` |
| Segments | four, aligned to 64K, so they map cleanly on 16K pages |
| Needs | `libc.so.6`, `libm.so.6`, `libdl.so.2`, `libpthread.so.0`, `libgcc_s.so.1`, `ld-linux-aarch64.so.1` |
| Imports | 410: 276 libc, 71 pthread, 42 libm, 10 libgcc_s, 5 libdl. Only `GLIBC_2.17` versions, the aarch64 baseline |
| Thread-local storage | 76 bytes |
| Direct system calls | **none.** There is no `svc #0` in its code. It reaches the kernel through libc, including libc's `syscall()` |
| Wine-specific exports | none. It is the ordinary Linux SDK, 679 exports |

  The last two rows matter. This library can be hosted by a loader and a glibc layer alone; the hypervisor idea in `SPEC.md` §9.3 is not needed for it. It imports `dlopen`, so what it loads at run time has to be inventoried the same way.

### The two Proton runtimes

Fetched with Valve's `steamcmd` into `.cache/steam-runtimes/` (not redistributed, not committed). An anonymous login is refused; a signed-in account gets both. `steamcmd` is x86_64 and runs under Rosetta, as a tool only.

| Runtime | App | Contents |
|---|---|---|
| Proton EasyAntiCheat Runtime | 1826330 | 284 KB. Bridge only: `easyanticheat_x64.dll` (PE, 72 KB) with `easyanticheat_x64.so` (ELF x86_64, 18 KB), and the i386 pair. No arm64 files |
| Proton BattlEye Runtime | 1161040 | 9.5 MB. Bridge `beclient_x64.dll` with `beclient_x64.so` (18 KB), the i386 pair, **and BattlEye's own client**: `BEClient_x64.so` (6.4 MB) and `BEClient.so` (i386) |

What the bridges are (import lists in `ledger/anticheat/`):

- **Both unix halves are thin.** Each is a Wine unix library exporting `__wine_unix_call_funcs`, with 17 imports: `dlopen`, `dlsym`, `malloc`, `free`, string functions and a few pthread calls. No direct system calls.
- **The EAC bridge** implements the older EasyAntiCheat client interface on the Windows side (`CreateGameClient`, `GameClientInterfaceV012`, `ClientAuthInterfaceV001`) and forwards to a Linux `easyanticheat_x64.so` that it opens and resolves the same names in. The game has to supply that file.
- **The BattlEye bridge** opens `$PROTON_BATTLEYE_RUNTIME/BEClient_x64.so` and resolves `Init` and `GetVer`.
- **BattlEye's client is the hard module.** 150 imports including libstdc++, a segment that is both writable and executable (it unpacks or rewrites itself), and up to 59 direct `syscall` instructions (an upper bound from a byte scan). It needs the FEX engine, which sees those.

### Elden Ring's real launcher

`start_protected_game.old` (the genuine EAC launcher; the file now named `start_protected_game.exe` is a copy of the game) contains, as plain strings: `wine_get_version`, `wine_get_unix_file_name`, `Starting Wine module mapping, Wine version: %s`, `Failed to initialize Wine helper buffer`, `Failed to locate the game binary (Wine)`, `/proc/%i/maps`, `/proc/self/fd/%i`, `/tmp/eac_wine_pid_%X`, `libc.so`, a Unix-socket path check, and platform names from `linux32` to `linux_x64_x86`.

Reading of that, **inferred from strings and not yet observed running**: Epic's Windows launcher detects Wine itself, reads the Linux process map, finds the host's libc in it and calls Linux directly. Valve's comment on commit `92c152e2b99` agrees: the EOS bootstrapper "will start the game process directly without using WINAPI". For Elden Ring, then, most of the anti-cheat path is Epic's own code and not Valve's bridge, and the arm64 SDK library exists for hosts where x86 code cannot call the host's libc.

What that means for the module host: the Linux view has to be reachable through Wine's file layer (`/proc/<pid>/maps`, `/tmp`), and the process has to contain a real x86_64 ELF `libc.so` image whose symbol table the launcher can walk and call into.

## Still open

- **Trace on Linux.** Run Elden Ring under Proton on x86_64 Linux with `strace` and `ltrace` to confirm the reading above: which libc functions the launcher calls, what it reads from `/proc`, and which module it then loads. Needs a Linux machine or VM.
- **Who loads `eossdk-win64-shipping.so`.** Needs an arm64 Linux Proton setup, or an answer from Epic.
- **Licence terms of the two runtimes.** Not stated in the downloads.
