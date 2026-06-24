"""Live hook-endpoint integration tests (Phase 02 wiring, US-004 AC#1/edge#1).

These bind the REAL :class:`HookEndpoint` on an autobound localhost port and POST
the canonical recorded fixture sequences over actual HTTP, then assert the shared
:class:`SessionRegistry` converged via the REAL :class:`StateReconciler` — no
mocks, no stubbed detector. They mirror TC-INT-001 (canonical hook sequence
normalized in order) and TC-INT-002 (dropped ``stop`` → JSONL reconvergence),
re-bound at the transport boundary instead of calling the reconciler directly.
"""

import json
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from http.client import HTTPConnection
from pathlib import Path

import pytest

from mission_control.detector.events import SessionState
from mission_control.detector.reconciler import StateReconciler
from mission_control.detector.registry import SessionRegistry
from mission_control.server.endpoint import HookEndpoint
from mission_control.server.ingest import IngestService

pytestmark = pytest.mark.integration

FIXTURES = Path(__file__).parent.parent / "fixtures" / "claude_hooks"


def _fixture_payloads(name: str) -> list[dict]:
    """Load a recorded fixture file as ordered raw payload dicts (as on the wire)."""
    lines = FIXTURES.joinpath(name).read_text().splitlines()
    return [json.loads(line) for line in lines if line.strip()]


@pytest.fixture
def endpoint() -> Iterator[HookEndpoint]:
    """A running endpoint over a frozen-clock service, torn down after the test."""
    frozen = datetime(2026, 6, 16, 12, 0, 0, tzinfo=UTC)
    service = IngestService(clock=lambda: frozen)
    server = HookEndpoint(service=service).start()
    try:
        yield server
    finally:
        server.stop()


def _post_hook(server: HookEndpoint, payload: dict) -> dict:
    """POST one payload to ``/hooks`` and return the parsed JSON response."""
    return _request(server, "POST", "/hooks", body=json.dumps(payload))


def _get(server: HookEndpoint, path: str) -> tuple[int, dict]:
    """GET ``path`` and return ``(status_code, parsed_json)``."""
    conn = HTTPConnection(server.host, server.port, timeout=5)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        return resp.status, json.loads(resp.read() or b"{}")
    finally:
        conn.close()


def _request(server: HookEndpoint, method: str, path: str, body: str) -> dict:
    """Issue one HTTP request and return the parsed JSON body."""
    conn = HTTPConnection(server.host, server.port, timeout=5)
    try:
        conn.request(method, path, body=body, headers={"Content-Type": "application/json"})
        return json.loads(conn.getresponse().read())
    finally:
        conn.close()


def test_canonical_hook_sequence_converges_to_done(endpoint: HookEndpoint) -> None:
    """TC-INT-001 (live): POSTing the canonical turn drives the registry to done."""
    states = [_post_hook(endpoint, p)["state"] for p in _fixture_payloads("normal_turn.jsonl")]

    # The per-POST responses trace the real transition path through reconciliation.
    assert states == ["running", "running", "waiting-for-input", "running", "done"]
    assert endpoint.service.status_of("sess-normal").state is SessionState.DONE


def test_waiting_for_input_is_observable_back_over_http(endpoint: HookEndpoint) -> None:
    """US-004 AC#2 (live): mid-turn the GET endpoint reports waiting-for-input."""
    payloads = _fixture_payloads("normal_turn.jsonl")
    for payload in payloads[:3]:  # up to and including the permission request.
        _post_hook(endpoint, payload)

    status_code, body = _get(endpoint, "/sessions/sess-normal")
    assert status_code == 200
    assert body["state"] == "waiting-for-input"


def test_dropped_stop_reconverges_to_done_via_jsonl(endpoint: HookEndpoint) -> None:
    """TC-INT-002 (live): a dropped stop hook still converges via a JSONL POST."""
    for payload in _fixture_payloads("dropped_stop.jsonl"):
        body = _post_hook(endpoint, payload)

    # Final POST is the JSONL turn-completed record; it reconciles to done.
    assert body["state"] == "done"
    assert endpoint.service.status_of("sess-dropped").state is SessionState.DONE


def test_rapid_transitions_settle_on_final_running(endpoint: HookEndpoint) -> None:
    """TC-INT-004 (live): a sub-second running→waiting→running burst settles on running.

    At the transport layer each POST is its own ingest (one event per request), so
    intra-batch coalescing does not apply — what must hold is that the *final*
    reconciled state is correct (``running``) and never sticks on the transient
    ``waiting-for-input``, even when the events arrive back-to-back over HTTP.
    """
    states = [
        _post_hook(endpoint, p)["state"] for p in _fixture_payloads("rapid_transitions.jsonl")
    ]

    assert states[-1] == "running"
    assert endpoint.service.status_of("sess-rapid").state is SessionState.RUNNING


def test_sessions_snapshot_lists_every_tracked_session(endpoint: HookEndpoint) -> None:
    """Phase 03 read path: GET /sessions returns one entry per tracked session."""
    for fixture in ("normal_turn.jsonl", "dropped_stop.jsonl"):
        for payload in _fixture_payloads(fixture):
            _post_hook(endpoint, payload)

    status_code, body = _get(endpoint, "/sessions")
    assert status_code == 200
    by_id = {s["session_id"]: s["state"] for s in body["sessions"]}
    assert by_id == {"sess-normal": "done", "sess-dropped": "done"}


def test_unknown_session_returns_404(endpoint: HookEndpoint) -> None:
    """Reads for an untracked session are an explicit 404, not a guessed state."""
    status_code, _ = _get(endpoint, "/sessions/never-seen")
    assert status_code == 404


def test_malformed_body_is_rejected_without_corrupting_state(endpoint: HookEndpoint) -> None:
    """A non-JSON body is a 400 and does not create a phantom session."""
    conn = HTTPConnection(endpoint.host, endpoint.port, timeout=5)
    headers = {"Content-Type": "application/json"}
    try:
        conn.request("POST", "/hooks", body="not json", headers=headers)
        assert conn.getresponse().status == 400
    finally:
        conn.close()

    status_code, body = _get(endpoint, "/sessions")
    assert status_code == 200
    assert body["sessions"] == []


def test_shared_registry_handle_is_the_one_phase_03_reads() -> None:
    """The endpoint reconciles into the same SessionRegistry instance handed in."""
    registry = SessionRegistry()
    service = IngestService(registry=registry, reconciler=StateReconciler(registry))
    server = HookEndpoint(service=service).start()
    try:
        for payload in _fixture_payloads("normal_turn.jsonl"):
            _post_hook(server, payload)
    finally:
        server.stop()

    # Phase 03 reads `registry` directly; it must see the reconciled state.
    assert registry.states() == {"sess-normal": SessionState.DONE}


def test_sweep_flips_silent_session_to_unknown() -> None:
    """TC-INT-003 (live ingest + periodic sweep): silence past threshold → unknown."""
    last = datetime(2026, 6, 16, 12, 0, 3, tzinfo=UTC)
    service = IngestService(clock=lambda: last + timedelta(seconds=31))
    for payload in _fixture_payloads("silent_after_running.jsonl"):
        service.ingest_payload(payload)
    assert service.status_of("sess-silent").state is SessionState.RUNNING

    service.sweep_stale()

    assert service.status_of("sess-silent").state is SessionState.UNKNOWN
