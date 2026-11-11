# Wine conformance on the macOS build

2026-11-11. Test programs from the Wine 11.20 test suite, run with MetalSharp Wine's `run-winetest.sh` on an Apple M6, macOS 27.2, for the six modules this work touches: ntdll, kernel32, kernelbase, ws2_32, advapi32 and msvcrt. **Unset `NoDefaultCurrentDirectoryInExePath` before running them** (see "Not Wine").

## Builds compared

1. **Unsigned, before any fixes.** `dist/files`, ad-hoc signed: 16K pages, nothing below 4GB, no i386. It matched the packaged MetalSharp Wine 6.0 unit for unit, so the Proton changes regress nothing.
2. **Unsigned, six fixes** (2026-11-10).
3. **Developer ID, six fixes.** `make app SIGN_IDENTITY=… PROFILE=…`: 4K pages, the low 4GB, i386 through FEX.
4. **Developer ID, fourteen fixes** (2026-11-11), the current build.

## Native ARM64

| Module | Units | Clean (1 → 2 → 3 → 4) | Failures (1 → 2 → 3 → 4) |
|---|---|---|---|
| ntdll | 27 | 20 → 22 → 24 → 24 | 219 → 193 → 134 → 6 |
| kernel32 | 33 | 27 → 29 → 28 → 28 | 280 → 243 → 154 → 114 |
| kernelbase | 6 | 5 → 5 → 6 → 6 | 4 → 4 → 0 → 0 |
| ws2_32 | 3 | 0 → 1 → 1 → 1 | 34 → 11 → 12 → 106 |
| advapi32 | 12 | 10 → 10 → 11 → 11 | 19 → 19 → 1 → 1 |
| msvcrt | 13 | 13 → 13 → 13 → 13 | 0 → 0 → 0 → 0 |
| All | 94 | 75 → 80 → 83 → 83 | 556 → 470 → 301 → 227 |

The ws2_32 count rose because `ws2_32:sock` now finishes. Before, it stopped at the runner's 300 second limit after its first 54 failures, hung on one of the bugs below; now it runs all 2,671,520 checks in 39 seconds, with 94 failures. `kernel32:loader` stops in every build (see "Not Wine").

Signing alone (build 2 to 3) cleared `ntdll:info`, `ntdll:virtual`, `ntdll:path`, `kernel32:file`, `kernelbase:process` and `advapi32:registry`.

## i386 through FEX

First run; i386 needs the signed build. Same six modules, build 4:

| Module | Units | Clean | Failures | Did not finish |
|---|---|---|---|---|
| ntdll | 27 | 22 | 17 | `exception` (time limit), `info` |
| kernel32 | 33 | 25 | 11 | `loader`, `debugger`, `virtual` |
| kernelbase | 6 | 6 | 0 | |
| ws2_32 | 3 | 1 | 10 | `sock` (time limit) |
| advapi32 | 12 | 11 | 1 | |
| msvcrt | 13 | 13 | 0 | |

Not looked at yet. The units that did not finish stop early and the runner records no summary for them; `kernel32:debugger` finished in one run and not in the next. In `ntdll:exception`, a privileged instruction raises `STATUS_ILLEGAL_INSTRUCTION` where Windows raises an access violation, and the unit then stops.

## Fixed

Fourteen commits on the `proton-macos` branch of the `wine` submodule, all fixes to MetalSharp Wine on macOS, independent of Proton.

**2026-11-10** (builds 2 and 3):

| Change | Unit | Failures |
|---|---|---|
| server: directory changes are reported as they happen, and a recursive watch follows subdirectories | ntdll:change, kernel32:change | 6 to 0, 10 to 0 |
| ws2_32: the computer's own bare name resolves; an unknown service is reported as one | ws2_32:protocol | 23 to 0 |
| ntdll: a thread that restricted its affinity is told it runs on one of its processors | ntdll:info | 11 fewer |
| ntdll: a path through a file is `STATUS_OBJECT_PATH_NOT_FOUND` on a case-insensitive volume | ntdll:path, ntdll:file | 4 to 0, 2 fewer |
| server: process memory counters on macOS | ntdll:info | 2 fewer |
| server: unreadable memory is `STATUS_PARTIAL_COPY` | ntdll:info | 1 fewer |

**2026-11-11** (build 4):

| Change | Unit | Effect |
|---|---|---|
| ntdll: reads open write-watched pages before reading, not after a fault | ws2_32:sock | hung; **data was lost** |
| server: a second TCP listener on an address is refused, and a reuse-bound socket holds its port only while listening or connecting | ws2_32:sock | hung |
| server: a TCP socket can connect again after a failed connect | ws2_32:sock | hung |
| server: a send or receive on an unconnected stream socket is tried at once | ws2_32:sock | hung |
| ntdll: socket options get their Windows values and sizes | ws2_32:sock | 49 failures to 4 |
| ntdll: `IP_UNICAST_IF` and `IPV6_UNICAST_IF` | ws2_32:sock | 16 to 0 |
| ntdll: copy-on-write protection of a read-only file view | kernel32:virtual | 40 to 0 |
| ntdll: selector queries answer as Windows does on ARM64 | ntdll:wow64 | 128 to 0, in each of its two processes |

**Write watches.** A read from a socket or pipe into write-watched memory faults; Wine opened the pages and read again. On Linux the data is still queued then. On macOS the read that faulted has already consumed it, so the data was lost. The .NET garbage-collected heap is write-watched, so a .NET program receiving into it lost network data. Outside Linux the pages are now opened first. A scan of the page flags without the lock keeps reads into ordinary memory as they were.

**TCP addresses.** Winsock's `SO_REUSEADDR` is `SO_REUSEPORT` on macOS. With it, BSD lets a second socket listen on an address another socket listens on and gives it the new connections. A socket only bound there takes them too, and drops them, so a connect waits 75 seconds. Windows keeps giving connections to the first listener and Linux refuses the second `listen()`. As on Linux, `listen()` and `bind()` on an address a TCP socket listens on are now refused. A TCP socket bound with `SO_REUSEADDR` gets a fresh, unbound kernel socket with the same options until it listens or connects; the server keeps its address for `getsockname()` and binds it again then. The same swap lets a socket connect again after a failed connect, which BSD refuses.

**Socket options.** BSD reports a set boolean option as its flag bit (8 for `SO_KEEPALIVE`); it is now 1. `IP_TOS`, `IP_TTL` and the IPv4 multicast options take and return one byte when given less than an int. An integer IPv6 option takes a buffer longer than an int. `TCP_KEEPCNT` refuses a count above 255.

**Read-only file views.** Outside Linux a read-only view of a file is mapped shared, because there a private mapping does not see later changes to the file; macOS confirms this. The host then refuses write access when the file was opened read-only, so `VirtualProtect(PAGE_WRITECOPY)` failed. The pages concerned are now replaced by private copies first.

## Not Wine

| Unit | Failures | Cause |
|---|---|---|
| kernel32:version | 27, in build 1 only | The shell the tests ran from had `NoDefaultCurrentDirectoryInExePath=1` set. Wine honours that Windows variable, so the test cannot start a program in the current directory |
| kernel32:loader | stops | Test 7 dereferences a NULL module on ARM64; an upstream test bug on every ARM64 platform (MetalSharp Wine's notes) |
| kernel32:virtual | 105 | Every DLL is linked with 64K section alignment, so that the same binaries load on 16K pages; the test expects a 4K header region of a `SEC_IMAGE` view |
| kernel32:module | 3 | The test expects imports in the order MSVC or GNU ld writes them; lld writes another |
| ntdll:file | 3 | Tests marked as expected failures on Wine that pass here |
| ntdll:wow64 | 2 | Both from its x64 child: the child expects Windows' x64 emulator `xtajit64.dll` (here FEX's `libarm64ecfex.dll`), and MetalSharp's ARM64EC `NtWriteVirtualMemory` sends an extra memory-write notice so that FEX drops code another process wrote |
| kernel32:toolhelp, kernel32:debugger | 4, 1 | The tests look for `wow64cpu.dll`, or `xtajit.dll`, in an i386 process; the i386 emulator here is FEX's `libwow64fex.dll` |
| ws2_32:sock | 2 | Marked to fail on Wine because Linux refuses a second listener on one address; on macOS the case runs as on Windows |

## Open

| Unit | Failures | State |
|---|---|---|
| ws2_32:sock | 92 | Many small differences, none a hang: out-of-band data events (14), bind (10), `WSAPoll` (9), `FIONREAD`/`SIOCATMARK` (8), address-list change notification (7), close events (6), `WSASocket` (6), reset connections (5), IPv4 control messages (5), and smaller groups. `IPV6_DONTFRAG` on a TCP socket is accepted and ignored by macOS |
| ws2_32:afd | 10 to 12 | Out-of-band data and half-closed sockets. macOS `poll()` never reports urgent data. kqueue's exception filter does, but also at the urgent-data mark and at every half-close. `poll()` reports a socket whose peer stopped sending as hung up with urgent data. A wineserver change built on these was tried and backed out: it made the results worse, and a level-triggered exception filter risks a busy server |
| kernel32:virtual | 1 | The store-buffer litmus test saw no reordering in eight runs with only a compiler barrier |
| ntdll:threadpool | 1 | Two timers that should fire together do not; every run, with msync on or off |
| advapi32:security | 1 | Four access-control entries where two are expected, from MetalSharp Wine's permissive ACLs for launchers |

## Not run

The x86_64 test builds (through FEX's ARM64EC), and the graphics, audio and input modules.
