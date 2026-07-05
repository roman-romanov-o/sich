#!/bin/sh
# Fully automated ON-SCREEN E2E smoke of the assembled ghostling app: boots the
# REAL window + sidecar + live poll, asserts the integration invariants no unit
# test can see (the EADDRINUSE / black-terminal class), and captures faithful
# screenshots of every surface to app/.artifacts/e2e/ for a design-critic pass.
# Exit code IS the verdict: 0 = all machine gates passed, 1 = real defect.
#
# Needs a GUI login session (it orders a window on screen). First run may prompt
# for Screen Recording permission — grant it once for full terminal capture.
set -e
cd "$(dirname "$0")/.."
swift build
set +e
GHOSTLING_E2E=1 swift run ghostling
rc=$?
echo "=== app/.artifacts/e2e/result.json ==="
cat .artifacts/e2e/result.json 2>/dev/null || echo "(no result.json written)"
exit $rc
