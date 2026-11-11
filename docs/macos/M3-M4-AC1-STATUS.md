# M3, M4 and AC1 status

2026-11-10. Milestones are defined in `SPEC.md` §15 and §9.7.

The Wine changes below are on the branch `proton-macos` of the `wine` submodule, nine commits on top of MetalSharp Wine 6.0 (`702b230e88d`): three for Proton, described here, and six fixes to MetalSharp Wine on macOS, described in `CONFORMANCE.md`. **The branch exists only in the local checkout.** It is not pushed, and the superproject still pins `702b230e88d`.

## M3: per-game rules for games Steam starts

**Done and tested.**

- `appcompat/extract.py` generates `appcompat/appcompat.env` from the launcher. It does not parse the launcher's source: it loads `proton` as a module, runs its session set-up once for each app id it names with the macOS paths on, and records how the environment differs from an app the launcher knows nothing about. The file has rules for 198 games and a `[*]` section for every game. `extract.py --check` fails when the file is out of date.
- The build installs it as `files/share/proton/appcompat.env`.
- Wine applies it at process start (`dlls/ntdll/unix/env.c`), before `launch.env`. The app id comes from `SteamAppId` or `SteamGameId`, or else from the app manifests of the Steam library the program is in.
- A variable the program's environment already has is kept, so the user's settings and `launch.env` win. A game's own section wins over `[*]`.

Tested in a copy of the dist: by `SteamAppId`, by `SteamGameId`, by a library folder with no variables set, a library folder with no rules, a program outside any library, a user value overriding a rule, and list values being added to `WINEDLLOVERRIDES`.

Not applied yet, recorded as comments in the file: the launcher's command-line additions, its FEX per-program overrides, and options that act on the prefix and not the environment. `PROTON_APPCOMPAT_DEBUG=1` prints what is applied.

## M4: Valve's Wine patches

**Measured, and the anti-cheat wave ported.**

`ledger/try_apply.py` cherry-picks every commit marked for porting onto MetalSharp Wine in order, keeping the ones that apply so later ones can build on them. The result is in the ledger's `applies` column.

| Class | Applies | Conflicts |
|---|---|---|
| W, Windows-side behaviour | 196 | 223 |
| S, Steam and Proton | 94 | 62 |
| M, media | 132 | 33 |
| G, graphics | 91 | 84 |
| I, input | 8 | 10 |
| All | 521 | 412 |

This is mechanical applicability only. The 521 sit on a scratch branch (`valve-applies` in `.cache/wine.git`) that has not been compiled or reviewed. None of it is a port.

**Ported by hand:** the final state of Valve's 17 anti-cheat commits, as one commit.

| Piece | State |
|---|---|
| BattlEye launcher redirect to `belauncher.exe`, and the program itself | Ported, builds, installed |
| `PROTON_EAC_LAUNCHER_PROCESS` for the EasyAntiCheat launcher | Ported |
| `PROTON_BATTLEYE_RUNTIME` and `PROTON_EAC_RUNTIME` on the builtin DLL path | Ported |
| EasyAntiCheat bridge load-order rule | Ported, adapted to 11.20's `get_load_order` |
| DNS exception for one game | Ported |
| EOS bootstrapper environment sync and forced en-US locale | Not ported: they need `__wine_set_unix_env`, a separate Valve commit |
| Instruction sequence in the x86_64 exception dispatcher | Not applicable: this build has no x86_64 ntdll |

These build and a prefix is created with them, but none of it has been exercised by an anti-cheat launcher.

## AC1: the Linux module host

**The mechanism works.** See `darwin/linuxhost/README.md`.

- A Linux x86_64 library runs inside a Wine process on macOS, translated by FEX, loaded by a host that is itself x86_64 Windows code.
- Valve's EasyAntiCheat and BattlEye bridge libraries load with no unresolved import and their constructors run.
- A direct Linux system call made by a library reaches the host. Before the Wine change it was taken for a Windows call: `getpid` (39) ran as `NtSetInformationFile` and returned `STATUS_ACCESS_VIOLATION`.

This changes the design in `SPEC.md` §9.3 in two ways, both simpler than planned:

1. **The host is Windows x86_64 code, not macOS code.** The glibc layer sits on the Windows C runtime, with no transitions to the unix side.
2. **System-call routing is a Wine change, not a FEX change.** FEX already hands every `syscall` to Wine's ntdll.

What AC1 still lacks is listed in the README. The largest items are the size of the glibc layer BattlEye's client needs, the `%fs` thread pointer, and connecting hosted libraries to Wine's `__wine_unix_call`.
