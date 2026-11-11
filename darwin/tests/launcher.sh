#!/bin/bash
# Tests of the proton launcher on macOS, against a built dist/.
#   darwin/tests/launcher.sh <dist dir> [work dir]
# Each test prints "ok" or "FAIL"; the exit status is the number of failures.
set -u
DIST=${1:?usage: launcher.sh <dist dir> [work dir]}
WORK=${2:-$(mktemp -d)}
P=$DIST/proton
export PROTON_STATE_DIR=$WORK/state
mkdir -p "$WORK"
fails=0

check() {  # check <name> <expected substring> <actual>
  if [[ $3 == *"$2"* ]]; then echo "ok    $1"; else echo "FAIL  $1: expected '$2' in '$3'"; fails=$((fails + 1)); fi
}
run() {  # run <compat dir> <proton args...>: stdout of the program, without Wine's messages
  local d=$1; shift
  mkdir -p "$d"
  STEAM_COMPAT_DATA_PATH=$d "$P" "$@" 2>/dev/null | tr -d '\r'
}

A=$WORK/compat-a

# the first run creates the default prefix and the prefix
out=$(run "$A" run cmd /c ver)
check "run: native ARM64 program" "Microsoft Windows" "$out"
check "default prefix created outside the dist" "default_pfx-" "$(ls "$PROTON_STATE_DIR")"
check "prefix version written" "11.0-" "$(cat "$A/version" 2>/dev/null)"
check "tracked files recorded" "drive_c/windows/system32" "$(grep -m1 'drive_c/windows/system32' "$A/tracked_files" 2>/dev/null)"
check "dist is not written to" "unchanged" "$([[ -z $(find "$DIST" -newer "$A/version" -type f 2>/dev/null | head -1) ]] && echo unchanged || echo modified)"

# verbs
check "runinprefix" "ARM64" "$(run "$A" runinprefix cmd /c 'echo %PROCESSOR_ARCHITECTURE%')"
check "waitforexitandrun" "Microsoft Windows" "$(run "$A" waitforexitandrun cmd /c ver)"
check "getcompatpath" 'Z:\tmp' "$(run "$A" getcompatpath /tmp)"
check "getnativepath" "/pfx/drive_c/windows" "$(run "$A" getnativepath 'C:\windows')"
check "steam: reports a prefix without Steam" "not installed" "$(mkdir -p "$A"; STEAM_COMPAT_DATA_PATH=$A "$P" steam 2>&1)"

# environment mapping
check "PROTON_USE_WINED3D selects Wine's Direct3D" "wine" "$(PROTON_USE_WINED3D=1 run "$A" run cmd /c 'echo %GRAPHICS_BACKEND%')"
check "PROTON_USE_DXVK selects DXVK" "dxvk" "$(PROTON_USE_DXVK=1 run "$A" run cmd /c 'echo %GRAPHICS_BACKEND%')"
check "PROTON_USE_VKD3D selects VKD3D-Proton" "vkd3d" "$(PROTON_USE_VKD3D=1 run "$A" run cmd /c 'echo %GRAPHICS_BACKEND%')"
check "the default leaves the lane to Wine" "%GRAPHICS_BACKEND%" "$(run "$A" run cmd /c 'echo %GRAPHICS_BACKEND%')"
check "PROTON_NO_FSYNC turns msync off" "0" "$(PROTON_NO_FSYNC=1 run "$A" run cmd /c 'echo %WINEMSYNC%')"
check "no built-in steam.exe override" "ok" "$(run "$A" run cmd /c 'echo %WINEDLLOVERRIDES%' | grep -q 'steam.exe' && echo bad || echo ok)"
check "no library path is set" "%LD_LIBRARY_PATH%" "$(env -u LD_LIBRARY_PATH bash -c "STEAM_COMPAT_DATA_PATH=$A '$P' run cmd /c 'echo %LD_LIBRARY_PATH%' 2>/dev/null")"

# FEX configuration
check "FEX config written per prefix" '"Config"' "$(cat "$A/proton-fex-config.json" 2>/dev/null)"
check "FEX config location points into the dist" "share/fex-emu" "$(run "$A" run cmd /c 'echo %FEX_APP_CONFIG_LOCATION%')"
check "STEAM_FEX_TSOENABLED reaches the config" '"TSOEnabled": "0"' "$(STEAM_FEX_TSOENABLED=0 run "$A" run cmd /c ver >/dev/null; cat "$A/proton-fex-config.json")"

# logging
PROTON_LOG=1 PROTON_LOG_DIR=$WORK SteamGameId=4242 run "$A" run cmd /c ver >/dev/null
check "PROTON_LOG writes steam-<appid>.log" "SteamGameId: 4242" "$(head -5 "$WORK/steam-4242.log" 2>/dev/null)"

# a second prefix is made from the default one, and destroyprefix removes what was tracked
B=$WORK/compat-b
check "second prefix" "Microsoft Windows" "$(run "$B" run cmd /c ver)"
run "$B" destroyprefix >/dev/null
check "destroyprefix removes tracked files" "gone" "$([[ -e $B/pfx/drive_c/windows/system32/kernel32.dll ]] && echo present || echo gone)"

# two launches at once share one prefix creation
C=$WORK/compat-c
run "$C" run cmd /c ver > "$WORK/c1.out" & run "$C" run cmd /c ver > "$WORK/c2.out"; wait
check "concurrent launches, first" "Microsoft Windows" "$(cat "$WORK/c1.out")"
check "concurrent launches, second" "Microsoft Windows" "$(cat "$WORK/c2.out")"

# per-game rules, which Wine itself applies to a program that has a Steam app id (games Steam starts)
if [[ -f $DIST/files/share/proton/appcompat.env ]]; then
  wine_env() { WINEPREFIX=$A/pfx WINEDEBUG=-all "$DIST/files/bin/wine" cmd /c "$1" 2>/dev/null | tr -d '\r'; }
  check "rules: a game's section, by SteamAppId" "16" "$(SteamAppId=298110 wine_env 'echo %WINE_CPU_TOPOLOGY%')"
  check "rules: the section for every game" "1" "$(SteamAppId=298110 wine_env 'echo %WINE_LARGE_ADDRESS_AWARE%')"
  check "rules: the game's value wins over every game's" "0" "$(SteamAppId=2710 wine_env 'echo %WINE_LARGE_ADDRESS_AWARE%')"
  check "rules: a value already set is kept" "4" "$(SteamAppId=298110 WINE_CPU_TOPOLOGY=4 wine_env 'echo %WINE_CPU_TOPOLOGY%')"
  check "rules: nothing without an app id" "%WINE_LARGE_ADDRESS_AWARE%" "$(wine_env 'echo %WINE_LARGE_ADDRESS_AWARE%')"
  check "rules: the database matches the launcher" "up to date" "$(python3 "$(dirname "$0")/../../appcompat/extract.py" --proton "$P" --check "$DIST/files/share/proton/appcompat.env" 2>&1)"
else
  echo "skip  per-game rules (no appcompat.env in the dist)"
fi

# x86_64 through FEX, when the test programs are built
BENCH=${BENCH:-$DIST/../tests/bin/bench-x86_64.exe}
if [[ -f $BENCH ]]; then
  check "run: x86_64 program under FEX" "checksum=13294612747242682073" "$(run "$A" run "$BENCH")"
else
  echo "skip  x86_64 program under FEX (no $BENCH)"
fi

"$DIST/files/bin/wineserver" -k 2>/dev/null
echo "$fails failure(s); work dir: $WORK"
exit $fails
