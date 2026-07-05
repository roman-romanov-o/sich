#!/usr/bin/env bash
# Capture step of the /design-review pipeline.
#
# Regenerates FAITHFUL screenshots of the current `ghostling` build by running the
# E2E harness (which boots the real window — single native binary, no sidecar —
# drives a drill-in + return, and captures each surface). screencapture is used
# when Screen Recording is granted; otherwise the permission-free CALayer.render
# fallback — both faithful.
#
# Output: app/.artifacts/e2e/{01-board,02-drillin-terminal,03-back-to-board}.png
# + result.json (the machine gates). Prints the shot paths for the critique step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ART="$ROOT/app/.artifacts/e2e"

rm -f "$ART"/*.png "$ART"/result.json 2>/dev/null || true

cd "$ROOT/app"
GHOSTLING_E2E=1 swift run ghostling

echo "=== design-review screenshots ==="
ls -1 "$ART"/*.png
