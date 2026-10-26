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
#         ./make-app.sh --dmg      # …and package build/Sich-<version>.dmg to hand out
#         ./make-app.sh --native   # arm64-only (faster; local use, NOT for sharing)
#         ./make-app.sh --version 0.3.0 --build-number 42   # stamp Info.plist (releases)
#         ./make-app.sh --sign "Developer ID Application: …"  # Developer ID + hardened runtime
#
# Without --sign the bundle is ad-hoc signed (fine locally, blocked by Gatekeeper
# elsewhere). The release workflow passes --sign and then notarizes the result.
#
# The default build is UNIVERSAL (arm64 + x86_64) because the artifact is meant to
# be shared — an arm64-only bundle simply won't launch on an Intel Mac.
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

make_dmg=false
install=false
version=""
build_number=""
sign_identity=""
arch_flags=(--arch arm64 --arch x86_64)
arch_label="universal (arm64 + x86_64)"
while [ $# -gt 0 ]; do
    case "$1" in
        --install) install=true ;;
        --dmg) make_dmg=true ;;
        --native) arch_flags=(); arch_label="native only — do not share this build" ;;
        --version) version="${2:?--version needs a value}"; shift ;;
        --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
        --sign) sign_identity="${2:?--sign needs an identity}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "▸ Building release binary — $arch_label (slow part; the resulting .app launches instantly)…"
# `${a[@]+"${a[@]}"}` — macOS ships bash 3.2, where an EMPTY array counts as
# unbound under `set -u`, so a plain "${arch_flags[@]}" aborts the --native build.
swift build -c release --product sich ${arch_flags[@]+"${arch_flags[@]}"}

BIN="$(swift build -c release --product sich ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)/sich"
[ -x "$BIN" ] || { echo "release binary not found at $BIN" >&2; exit 1; }

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/sich"
cp packaging/Info.plist "$CONTENTS/Info.plist"
# The tag is the single source of truth for a release's version; the checked-in
# plist keeps a placeholder. Stamp BEFORE signing so the seal covers the real values.
if [ -n "$version" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$CONTENTS/Info.plist"
fi
if [ -n "$build_number" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$CONTENTS/Info.plist"
fi

# The harness marks must live in the app's OWN Contents/Resources: SwiftPM's
# `Bundle.module` accessor falls back to the absolute `.build` path of the machine
# that compiled it, which is a fatalError on anyone else's Mac (see
# BoardTheme.markURL). Copying them here keeps a shared bundle self-contained.
cp Sources/SichApp/Resources/*.pdf "$RESOURCES/"

echo "▸ Rendering icon …"
ICONSET="$BUILD_DIR/$APP_NAME.iconset"
ICON_SOURCE="../assets/sich-icon.png"
rm -rf "$ICONSET"
swift packaging/make-icon.swift "$ICONSET" "$ICON_SOURCE"
iconutil -c icns "$ICONSET" -o "$RESOURCES/$APP_NAME.icns"
rm -rf "$ICONSET"

if [ -n "$sign_identity" ]; then
    # Developer ID + hardened runtime + secure timestamp: what notarization requires.
    # No --deep: the bundle has exactly one Mach-O (Contents/MacOS/sich), so signing
    # the bundle signs it, and --deep is documented as unsuitable for release signing.
    echo "▸ Signing with \"$sign_identity\" …"
    codesign --force --options runtime --timestamp --sign "$sign_identity" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    # An unsigned local bundle still launches; ad-hoc sign so Gatekeeper/TCC treat it as
    # one stable identity across rebuilds (keeps notification + accessibility grants).
    codesign --force --deep --sign - "$APP" 2>/dev/null || \
        echo "  (codesign skipped — bundle still runs locally, unsigned)"
fi

echo "✓ Built $APP"

if [ "$make_dmg" = true ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
    DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
    STAGE="$BUILD_DIR/dmg-stage"
    echo "▸ Packaging $DMG …"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    if [ -z "$sign_identity" ]; then
        # An ad-hoc signed, un-notarized bundle is blocked by Gatekeeper on first
        # launch. Ship the way out in the disk image itself — nobody reads a link.
        cp packaging/FIRST-LAUNCH.txt "$STAGE/FIRST LAUNCH — READ ME.txt"
    fi
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✓ Packaged $(cd "$BUILD_DIR" && pwd)/$APP_NAME-$VERSION.dmg ($(du -h "$DMG" | cut -f1))"
    if [ -z "$sign_identity" ]; then
        echo "  Share that file. Recipient: open it, drag Sich to Applications, then follow"
        echo "  'FIRST LAUNCH — READ ME.txt' (the app is unsigned, so macOS blocks run #1)."
    fi
fi

if [ "$install" = true ]; then
    echo "▸ Installing to /Applications …"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "✓ Installed. Launch it from Spotlight or /Applications."
fi
