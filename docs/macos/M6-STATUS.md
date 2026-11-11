# M6 status: the application bundle and signing

2026-11-10. M6 is defined in `SPEC.md` §15.

## What works

`make app` builds `dist/MetalSharp-Wine.app` with MetalSharp Wine's `sign-app.sh` and puts Proton's files in it:

```
MetalSharp-Wine.app/Contents/
  MacOS/            wine, wineserver and the tools
  lib/  share/      the Wine tree; lib/wine/aarch64-unix/wine.app is the inner loader's own bundle
  bin -> MacOS
  Resources/
    proton  filelock.py  version  user_settings.sample.py  LICENSE*
    files -> ..     so the launcher finds files/bin/wine, files/lib and files/share as in dist/
```

Checked with an ad-hoc signature:

- `codesign --verify --strict --deep` passes, before and after use.
- `darwin/tests/launcher.sh` passes when pointed at `Contents/Resources`, so the launcher, the prefix manager and the per-game rules work from inside the bundle.
- Running it writes nothing into the bundle. The default prefix goes to `~/Library/Application Support`.

## Not done

- **A Developer ID build has not been made.** The machine has a Developer ID identity and MetalSharp Wine's provisioning profile, and the command is

  ```bash
  make app SIGN_IDENTITY="Developer ID Application: <name> (<team>)" PROFILE=<path>/MetalSharp_Wine.provisionprofile
  ```

  It was not run because it decides the bundle's identity (`SPEC.md` §17, decision 1): the profile is for `com.metalsharp.wine`, so the result is MetalSharp Wine's app carrying Proton, not an app of its own. Only this build gets the cross-architecture entitlement, and with it 4K pages and i386 programs.
- **Notarization** (`xcrun notarytool`), which sends the bundle to Apple.
- **A bundled Python.** The launcher runs with the system Python that the developer tools install.
- **The name and the bundle identifier** are MetalSharp Wine's.

## A problem in MetalSharp Wine's `sign-app.sh`

Without an identity the script stops at its profile lookup: `PROFILE=${PROFILE:-$( [[ $IDENTITY != - ]] && ls … )}` fails under `set -e` when the test is false, so the ad-hoc build its header describes cannot be made. `make app` runs a copy with `|| true` added to that line.
