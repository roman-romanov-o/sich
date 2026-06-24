"""Live transport for the detector (Phase 02 wiring, US-004).

The detector logic core (``mission_control.detector``) is transport-free. This
package is the thin async-ish HTTP shim that delivers real Claude Code hook
POSTs into it and exposes the reconciled state back for Phase 03's board:

  - :class:`IngestService` — normalize → reconcile → tick (wall-clock injected),
    writing through to the shared :class:`SessionRegistry`.
  - :class:`HookEndpoint`  — a local ``127.0.0.1`` HTTP server fronting it.

It adds no web dependency (stdlib :mod:`http.server`) and never spawns an agent.
"""

from mission_control.server.endpoint import (
    HookEndpoint,
    SessionStateResponse,
    SnapshotResponse,
)
from mission_control.server.ingest import IngestService, normalize_payload

__all__ = [
    "HookEndpoint",
    "IngestService",
    "SessionStateResponse",
    "SnapshotResponse",
    "normalize_payload",
]
