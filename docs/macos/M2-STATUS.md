# M2 status: the `proton` launcher on macOS

2026-11-10. M2 is defined in `SPEC.md` §15.

## What runs

`dist/proton` runs on macOS with the system Python 3.9. The changes are in `proton` itself, each behind `IS_DARWIN`, so the Linux paths are untouched.

| Area | macOS behaviour |
|---|---|
| Verbs | `run`, `waitforexitandrun`, `runinprefix`, `destroyprefix`, `getcompatpath`, `getnativepath` work as upstream. New: `steam` starts the Windows Steam client installed in the prefix |
| Default prefix | Made on first use with `wineboot`, under `~/Library/Application Support/Proton-macOS/default_pfx-<build>` (`PROTON_STATE_DIR` overrides). The distribution is never written to, so it can sit in a signed app bundle. It is built under a temporary name and renamed, so an interrupted creation is not taken for a prefix |
| Prefix creation | Proton's own: the default prefix is copied into `$STEAM_COMPAT_DATA_PATH/pfx`, with tracked files, the version file and upgrades. Files are APFS clones (`clonefile`) |
| Steam files | None staged. Games use the real Windows client's files; there is no built-in `steam.exe`, and its DLL override is dropped |
| Direct3D | Nothing is copied into the prefix. `PROTON_USE_WINED3D` sets `GRAPHICS_BACKEND=wine`, and the new `PROTON_USE_DXVK` and `PROTON_USE_VKD3D` select those lanes. The default leaves the choice to Wine (Mullion) |
| Sync | `PROTON_NO_FSYNC` sets `WINEMSYNC=0` |
| Libraries | No `LD_LIBRARY_PATH`, `WINEDLLPATH` or GStreamer path is set; the Wine tree finds its own |
| FEX | The per-prefix `proton-fex-config.json`, `FEX_APP_CONFIG` and `FEX_APP_CONFIG_LOCATION` are set as on arm64 Linux |
| Program start | The program is started directly, without Proton's `steam.exe` helper |

## Tested

`darwin/tests/launcher.sh <dist>` runs 26 checks: every verb, the default prefix location, tracked files, the environment mapping, the FEX config, logging, a second prefix, `destroyprefix`, two launches at once, and an x86_64 program under FEX. All pass on the current build.

Timing on an Apple M6: the first run, which builds the default prefix and the first game prefix, takes 16 seconds; later runs take about 3.

## Not done

- **A bundled Python.** The script runs with the system Python that the developer tools install; a release needs its own.
- **`steam` against a real Steam install.** The verb is tested only for the case where Steam is absent.
- **Proton's per-app prefix fixes in `upgrade_pfx`** have not been reviewed for a prefix shared by all Steam games (`SPEC.md` §8.3).
- **The state directory name** follows the working name "Proton-macOS".
- **Wine Mono is missing from prefixes made by an unsigned build**, because its installer runs two i386 helper programs.
