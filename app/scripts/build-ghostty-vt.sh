#!/usr/bin/env bash
# Rebuild the vendored libghostty-vt static archives.
#
# The headers, module map and Info.plist of app/Frameworks/ghostty-vt.xcframework
# are tracked in git (the ABI of record); the ~16 MB *.a slices are not. This
# script builds ghostty's `lib-vt` target at the pinned revision and copies ONLY
# the static archives into the tracked xcframework, slice by slice, so the
# tracked headers stay the source of truth.
#
# Pins (change both here and nowhere else — CI keys its cache on this file):
GHOSTTY_REV=ae52f97dcac558735cfa916ea3965f247e5c6e9e
ZIG_VERSION=0.15.2
#
# Requirements: git, Xcode command line tools (xcodebuild is what produces the
# xcframework), and Zig ${ZIG_VERSION} on PATH — Homebrew ships a newer Zig that
# does NOT build this revision; get 0.15.2 from https://ziglang.org/download/.
#
# Usage:
#   app/scripts/build-ghostty-vt.sh            # build in a temp dir, install the slices
#   GHOSTTY_BUILD_DIR=~/src/ghostty-build app/scripts/build-ghostty-vt.sh   # keep the checkout
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
dest="$app_dir/Frameworks/ghostty-vt.xcframework"
work="${GHOSTTY_BUILD_DIR:-$(mktemp -d -t ghostty-vt)}"
src="$work/ghostty"

have_zig="$(zig version 2>/dev/null || true)"
if [ "$have_zig" != "$ZIG_VERSION" ]; then
  echo "error: need Zig $ZIG_VERSION on PATH (found '${have_zig:-none}')." >&2
  exit 1
fi
command -v xcodebuild >/dev/null || { echo "error: xcodebuild not found; install Xcode." >&2; exit 1; }

if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$src" fetch -q --depth 1 origin "$GHOSTTY_REV"
git -C "$src" checkout -q --detach FETCH_HEAD

# `-Demit-lib-vt` scopes the build to libghostty-vt; on a Mac with xcodebuild it
# also emits the universal (macOS + iOS + simulator) xcframework by default.
(cd "$src" && zig build -Demit-lib-vt -Doptimize=ReleaseFast)

built="$src/zig-out/lib/ghostty-vt.xcframework"
[ -d "$built" ] || { echo "error: $built was not produced." >&2; exit 1; }

# Copy the archives only, preserving the slice directories, next to the tracked headers.
rsync -a --include='*/' --include='*.a' --exclude='*' "$built/" "$dest/"
find "$dest" -name '*.a' -exec ls -lh {} \;
lipo -archs "$dest/macos-arm64_x86_64/libghostty-vt.a"
