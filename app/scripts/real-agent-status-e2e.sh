#!/bin/sh
# Opt-in smoke against the real installed Claude and Codex CLIs. It routes both
# through Ghostling's scoped shims and uses --help only, so it does not start model
# turns or spend quota.
set -e
cd "$(dirname "$0")/.."
GHOSTLING_REAL_AGENT_E2E=1 GHOSTLING_REAL_CODEX_TURN_E2E=1 swift test --filter RealAgentStatusE2ETests
