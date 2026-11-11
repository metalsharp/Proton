#!/bin/bash
# Check that this Mac can build the darwin target. Prints what is missing and exits 1 if anything is.
missing=0
need() {  # need <command> <how to get it>
  if ! command -v "$1" >/dev/null 2>&1; then
    echo >&2 "!! missing: $1 ($2)"
    missing=1
  fi
}

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo >&2 "!! the darwin target builds on Apple Silicon macOS only"; exit 1; }

if ! xcodebuild -version >/dev/null 2>&1; then
  echo >&2 "!! Xcode is not the active developer directory ($(xcode-select -p 2>/dev/null))."
  echo >&2 "!! Point it at Xcode: sudo xcode-select -s <Xcode.app>/Contents/Developer"
  missing=1
fi
xcrun --find metal >/dev/null 2>&1 || { echo >&2 "!! missing: Metal toolchain (xcodebuild -downloadComponent MetalToolchain)"; missing=1; }

need zsh "part of macOS"
need cmake "brew install cmake"
need ninja "brew install ninja"
need meson "brew install meson"
need nasm "brew install nasm"
need rsync "part of macOS"
[[ -x /opt/homebrew/bin/pkgconf ]] || { echo >&2 "!! missing: /opt/homebrew/bin/pkgconf (brew install pkgconf)"; missing=1; }
for keg in bison flex gettext; do
  [[ -d /opt/homebrew/opt/$keg/bin ]] || { echo >&2 "!! missing: Homebrew $keg (brew install $keg)"; missing=1; }
done

exit $missing
