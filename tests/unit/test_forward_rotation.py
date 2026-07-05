"""TC-PROD-005 — producer-side rotation of the hook event log (US-001 AC3).

The forwarder `.claude/scripts/ghostling-forward.sh` is a bash script, not Swift, so
this one producer test is pytest. It drives the script via subprocess with a temp
`GHOSTLING_EVENTS_FILE` and a small `GHOSTLING_EVENTS_MAX_BYTES`, feeds enough bytes to
cross the threshold, and asserts the live log gets rotated to `events.jsonl.1` while the
live file stays bounded — and that the forwarder always exits 0 (a write hiccup must
never fail the watched session).
"""

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FORWARDER = REPO_ROOT / ".claude" / "scripts" / "ghostling-forward.sh"

LINE = '{"hook_event_name":"PreToolUse","session_id":"S","tool_name":"Edit"}'


def _forward(payload: str, events_file: Path, max_bytes: int) -> int:
    env = {
        **os.environ,
        "GHOSTLING_EVENTS_FILE": str(events_file),
        "GHOSTLING_EVENTS_MAX_BYTES": str(max_bytes),
    }
    result = subprocess.run(["bash", str(FORWARDER)], input=payload, text=True, env=env)
    return result.returncode


def test_forwarder_rotates_past_threshold(tmp_path):
    events = tmp_path / "events.jsonl"
    rotated = tmp_path / "events.jsonl.1"
    max_bytes = 512

    # Feed enough lines (~68 bytes each) to cross the 512-byte threshold several times.
    for _ in range(40):
        assert _forward(LINE, events, max_bytes) == 0  # always exit 0

    # US-001 AC3: older events moved to the rotated file, live log stays bounded.
    assert rotated.exists(), "events.jsonl.1 must appear once the log crosses the threshold"
    assert rotated.stat().st_size > 0, "the rotated generation must hold the overflow"

    # The live file the app tails stays bounded: either it was just rotated away (recreated
    # on the next append) or it is at most the threshold. Never unbounded.
    live_size = events.stat().st_size if events.exists() else 0
    assert live_size <= max_bytes, "the live log must stay bounded after rotation"
