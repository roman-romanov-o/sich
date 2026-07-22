#!/usr/bin/env bash
# Build Sich.app — a real, double-clickable macOS bundle.
#
# Why this exists (the "startup lag" goal item): running via `swift run sich`
# recompiles/links on every launch, so there is a multi-second stall before the
# window appears. A prebuilt RELEASE binary inside a proper `.app` launches
# instantly, and the bundle also gives the app its real name ("Sich") and icon
# instead of the bare `sich` executable name and a generic icon.
#
# Usage:  ./make-app.sh            # build + assemble into ./build/Sich.app
#         ./make-app.sh --install  # …then copy to /Applications
#
# Re-run after code changes to refresh the bundled binary.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Sich"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Building release binary (this is the slow part; the resulting .app launches instantly)…"
swift build -c release --product sich

BIN="$(swift build -c release --product sich --show-bin-path)/sich"
[ -x "$BIN" ] || { echo "release binary not found at $BIN" >&2; exit 1; }

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/sich"
cp packaging/Info.plist "$CONTENTS/Info.plist"

echo "▸ Rendering icon …"
ICONSET="$BUILD_DIR/$APP_NAME.iconset"
ICON_SOURCE="../assets/sich-icon.png"
rm -rf "$ICONSET"
swift packaging/make-icon.swift "$ICONSET" "$ICON_SOURCE"
iconutil -c icns "$ICONSET" -o "$RESOURCES/$APP_NAME.icns"
rm -rf "$ICONSET"

# An unsigned local bundle still launches; ad-hoc sign so Gatekeeper/TCC treat it as
# one stable identity across rebuilds (keeps notification + accessibility grants).
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "  (codesign skipped — bundle still runs locally, unsigned)"

echo "✓ Built $APP"
if [ "${1:-}" = "--install" ]; then
    echo "▸ Installing to /Applications …"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "✓ Installed. Launch it from Spotlight or /Applications."
fi
