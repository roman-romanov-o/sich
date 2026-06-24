#!/usr/bin/env bash
# Build + run the Phase 00 in-process PTY-read smoke against libghostty-vt.
#
# By default it links the xcframework vendored in the repo (app/Frameworks),
# so the spike no longer depends on the /tmp recon build. Override the slice
# (headers + static lib) with:
#   GHOSTTY_SLICE=/path/to/slice ./build.sh          # dir with Headers/ + libghostty-vt.a
#   GHOSTTY_OUT=/path/to/zig-out  ./build.sh          # raw zig-out layout
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VENDORED="$REPO/app/Frameworks/ghostty-vt.xcframework/macos-arm64_x86_64"

if [ -n "${GHOSTTY_OUT:-}" ]; then
    INC="$GHOSTTY_OUT/include"
    LIB="$GHOSTTY_OUT/lib/libghostty-vt.a"
else
    SLICE="${GHOSTTY_SLICE:-$VENDORED}"
    INC="$SLICE/Headers"
    LIB="$SLICE/libghostty-vt.a"
fi

[ -d "$INC" ] || { echo "missing headers: $INC" >&2; exit 3; }
[ -f "$LIB" ] || { echo "missing static lib: $LIB (rebuild: see app/Frameworks/README.md)" >&2; exit 3; }

clang -std=c11 -Wall -Wextra -I "$INC" "$HERE/smoke.c" "$LIB" -o "$HERE/smoke"
echo "built: $HERE/smoke  (linked: $LIB)"
echo
"$HERE/smoke"
