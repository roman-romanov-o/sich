#!/bin/sh
# Opt-in E2E against the REAL installed Claude and Codex CLIs (spends interactive
# quota, takes minutes). Two suites:
#   - RealAgentStatusE2ETests: quota-free shim-resolution smoke.
#   - CardStatusRealAgentE2ETests: the full CARD-STATUS.md journeys — agents typed
#     into a real board card PTY, asserted at board-column level.
set -e
cd "$(dirname "$0")/.."
GHOSTLING_REAL_AGENT_E2E=1 swift test \
    --filter 'RealAgentStatusE2ETests|CardStatusRealAgentE2ETests'
