"""Agentic Coding Mission Control — Python sidecar.

Headless, quota-safe core that backs the Swift/libghostty app:
  - ``detector`` — Claude Code session state detection (US-004 / Phase 02).
  - ``quota``    — two-pool quota model + window math (US-006 / Phase 04).
  - ``board``    — pure derivations: state→column placement, attention count.

This package never spawns ``claude -p`` and never spends quota.
"""

__version__ = "0.1.0"
