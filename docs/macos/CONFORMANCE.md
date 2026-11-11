# Wine conformance on the macOS build

2026-11-10. Native ARM64 test programs from the Wine 11.20 test suite, run with MetalSharp Wine's `run-winetest.sh` against the unsigned `dist/files` on an Apple M6, macOS 27.2.

Three runs of the same test binaries on the same machine:

1. **MetalSharp Wine 6.0**, the packaged `metalsharp-wine-6.0-arm64`, as the reference.
2. **This build before the fixes**: 6.0 plus the per-game rules, the anti-cheat pieces and the system-call routing.
3. **This build after the fixes** below.

Runs 1 and 2 agree unit for unit, apart from two single failures that come and go with timing, so the Proton changes regress nothing. Run 3 is the same machine and prefix layout with one stray environment variable removed (see below).

## Results

| Module | Units | Clean, before | Clean, after | Failures, before | Failures, after |
|---|---|---|---|---|---|
| ntdll | 27 | 20 | 22 | 219 | 193 |
| kernel32 | 33 | 27 | 29 | 280 | 243 |
| kernelbase | 6 | 5 | 5 | 4 | 4 |
| ws2_32 | 3 | 0 | 1 | 34 | 11 |
| advapi32 | 12 | 10 | 10 | 19 | 19 |
| msvcrt | 13 | 13 | 13 | 0 | 0 |
| All | 94 | 75 | 80 | 556 | 470 |

`ws2_32:sock` does not finish in either run: it stops at the runner's 300 second limit after 54 failures.

## Fixed

Six commits on the `proton-macos` branch of the `wine` submodule. All are fixes to MetalSharp Wine on macOS, independent of Proton.

| Change | Unit | Failures |
|---|---|---|
| server: directory changes are reported as they happen, and a recursive watch follows subdirectories | ntdll:change, kernel32:change | 6 to 0, 10 to 0 |
| ws2_32: the computer's own bare name resolves; an unknown service is reported as one | ws2_32:protocol | 23 to 0 |
| ntdll: a thread that restricted its affinity is told it runs on one of its processors | ntdll:info | 11 fewer |
| ntdll: a path through a file is `STATUS_OBJECT_PATH_NOT_FOUND` on a case-insensitive volume | ntdll:path, ntdll:file | 4 to 0, 2 fewer |
| server: process memory counters on macOS | ntdll:info | 2 fewer |
| server: unreadable memory is `STATUS_PARTIAL_COPY` | ntdll:info | 1 fewer |

**Directory changes.** The server rescanned watched directories every 50 ms. A program that changed a directory and asked at once was told nothing had changed, and a recursive watch never looked below the top level. The kernel now reports a watched directory whose entries change (`EVFILT_VNODE` on the main loop's kqueue), and the scan runs before the requests that arrived with it. A recursive watch follows subdirectories up to 16 levels, 8,192 entries and 64 open subdirectories; past those limits the rest of the tree is not seen. The 50 ms poll stays for changes to the files themselves.

**The computer's own name.** macOS resolves `<name>.local` but not the bare `<name>`, which is what Windows programs are given as the computer name. A program looking up the host it runs on got `WSAHOST_NOT_FOUND`.

## Not Wine

| Unit | Failures | Cause |
|---|---|---|
| kernel32:version | 27 | The shell the tests were started from had `NoDefaultCurrentDirectoryInExePath=1` set. It is a Windows variable, Wine honours it, and the test then cannot start a program in the current directory. Gone with the variable unset. **Unset it before running the tests** |
| kernel32:module | 3 | The test expects the test program's imports in the order MSVC or GNU ld writes them; lld writes another |
| ntdll:file | 3 | Tests marked as expected failures on Wine that pass here |

## Needs the signed build

An unsigned build has 16K pages and nothing below 4GB. These go away in the Developer ID bundle, which has 4K pages and the low 4GB; none can be fixed in code.

| Unit | Failures | Cause |
|---|---|---|
| kernel32:virtual, ntdll:virtual | 225, 40 | 4K-granular protections, guard pages and region sizes |
| ntdll:wow64 | 143 | i386 processes cannot start |
| kernel32:file | 8 | a buffer with a no-access page 8K into a 16K page |
| ntdll:info | 6 | `KUSER_SHARED_DATA` is not at `0x7ffe0000` |
| kernelbase:process | 4 | placeholder splitting at 4K |
| advapi32:registry | 18 | the 32-bit view of `Software\Classes\Interface` is never created, because the i386 setup steps cannot run. Likely, not confirmed on a signed build |

## Open

| Unit | Failures | State |
|---|---|---|
| ws2_32:sock | 54, then the time limit | socket options and error codes where macOS differs from Linux; not looked at one by one |
| ws2_32:afd | 10 | out-of-band data and poll flags; one more or less with timing |
| kernel32:loader | 7 | MetalSharp Wine's notes call test 7 an upstream test bug on ARM64 |
| ntdll:threadpool | 1 | two timers that should fire together do not; fails every run, with msync on or off; cause not found |
| advapi32:security | 1 | four access-control entries where two are expected, from MetalSharp Wine's permissive ACLs for launchers |

## Not run

Only these six modules were run, the ones this work touched. The x86_64 and i386 test builds, which run under FEX, were not run, and neither were the graphics, audio or input modules.
