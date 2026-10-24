#!/usr/bin/env bash
# Register the Sich board's hook forwarder with Claude Code so REAL
# interactive sessions in this project appear on the mission-control board.
#
# Run this ONCE, yourself:   bash .claude/scripts/enable-board-hooks.sh
#
# It edits .claude/settings.json — config Claude Code loads at startup — which is
# why the agent can't write it for you (a self-modification guardrail). The merge
# is idempotent (safe to re-run) and preserves every hook already there. Undo by
# deleting the sich-forward.sh entries it adds.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

python3 - <<'PY'
import json, pathlib
p = pathlib.Path(".claude/settings.json")
cfg = json.loads(p.read_text()) if p.exists() else {}
hooks = cfg.setdefault("hooks", {})
FORWARD = "bash .claude/scripts/sich-forward.sh"
# Lifecycle events the board cares about: appear → run → wait → done.
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "Notification", "Stop"]

def already_forwarding(groups):
    return any(h.get("command") == FORWARD
               for g in groups for h in g.get("hooks", []))

for event in EVENTS:
    groups = hooks.setdefault(event, [])
    if already_forwarding(groups):
        continue  # idempotent — don't double-add on re-run
    # Reuse an existing matcher-"" group (e.g. SessionStart's welcome) if present.
    target = next((g for g in groups if g.get("matcher", "") == ""), None)
    if target is None:
        target = {"matcher": "", "hooks": []}
        groups.append(target)
    target["hooks"].append({"type": "command", "command": FORWARD})

p.write_text(json.dumps(cfg, indent=2) + "\n")
print("✓ board hooks registered for:", ", ".join(EVENTS))
print("  Restart this Claude Code session (or start a new one in this repo) to load them.")
PY
