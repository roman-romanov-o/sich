#!/usr/bin/env bash
# Package a built Sich.app into a drag-to-Applications disk image.
#
# Usage:  packaging/make-dmg.sh <path/to/Sich.app> <out.dmg> [--sign "Developer ID Application: …"]
#
# Kept apart from make-app.sh so the release workflow can notarize and staple the
# app FIRST and then wrap the stapled bundle: a copy dragged out of the image then
# carries its own ticket and clears Gatekeeper offline. With --sign the image itself
# is signed too, so it can be notarized and stapled as the outer container.
set -euo pipefail

app="${1:?usage: make-dmg.sh <Sich.app> <out.dmg> [--sign identity]}"
dmg="${2:?usage: make-dmg.sh <Sich.app> <out.dmg> [--sign identity]}"
shift 2
sign_identity=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) sign_identity="${2:?--sign needs an identity}"; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

packaging="$(cd "$(dirname "$0")" && pwd)"
stage="$(dirname "$dmg")/dmg-stage"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
# ditto keeps the code signature, stapled ticket and extended attributes intact.
ditto "$app" "$stage/Sich.app"
ln -s /Applications "$stage/Applications"
if [ -z "$sign_identity" ]; then
    # An ad-hoc signed, un-notarized bundle is blocked by Gatekeeper on first
    # launch. Ship the way out in the disk image itself — nobody reads a link.
    cp "$packaging/FIRST-LAUNCH.txt" "$stage/FIRST LAUNCH — READ ME.txt"
fi
hdiutil create -volname Sich -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$stage"
if [ -n "$sign_identity" ]; then
    codesign --force --timestamp --sign "$sign_identity" "$dmg"
    codesign --verify --verbose=2 "$dmg"
fi
echo "✓ Packaged $dmg ($(du -h "$dmg" | cut -f1))"
