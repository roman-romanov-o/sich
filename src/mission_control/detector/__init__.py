"""Claude Code session state detection (US-004 / Phase 02).

The critical-feasibility layer: ingest Claude Code hook events, reconcile them
with JSONL/PTY signals under a precedence order (hooks → JSONL → PTY), classify
into a :class:`SessionState`, and write it onto a :class:`SessionRegistry` for
the board to read.

Design seams (so later providers and the timing tests stay clean):
  - :func:`normalize_hook` — provider payload → typed :class:`SignalEvent`.
  - :func:`classify` — pure ``(prior, signal) → state``; ambiguous → ``unknown``.
  - :class:`StateReconciler` — multi-source precedence, coalescing, staleness;
    clock injected, never read internally.

This package never spawns ``claude -p`` and never talks to a live agent — all
tests run against recorded fixture sequences.
"""

from mission_control.detector.classifier import classify
from mission_control.detector.events import (
    SessionState,
    SignalEvent,
    SignalKind,
    SignalSource,
)
from mission_control.detector.hook_receiver import normalize_hook, normalize_sequence
from mission_control.detector.reconciler import (
    StateReconciler,
    StateTransition,
    reconcile_stream,
)
from mission_control.detector.registry import SessionRegistry, SessionStatus

__all__ = [
    "SessionRegistry",
    "SessionState",
    "SessionStatus",
    "SignalEvent",
    "SignalKind",
    "SignalSource",
    "StateReconciler",
    "StateTransition",
    "classify",
    "normalize_hook",
    "normalize_sequence",
    "reconcile_stream",
]
