"""Live HTTP hook endpoint — the Phase 02 transport boundary (US-004 wiring).

A thin local receiver for Claude Code hook POSTs. It owns *no* detection logic:
each request body is handed to the shared :class:`IngestService`, which routes
it through the existing detector normalizers + :class:`StateReconciler`. The
endpoint only does transport — read body, parse JSON, dispatch route, serialize
the resulting :class:`SessionStatus` back as JSON.

Bound to ``127.0.0.1`` only (watcher discipline: a local sidecar surface, never
a spawner). Built on the stdlib :mod:`http.server` so the sidecar adds no async
web dependency; ``ThreadingHTTPServer`` lets concurrent hook POSTs land safely.

Routes:
  - ``POST /hooks``            ingest one hook/JSONL payload → that session's status
  - ``GET  /sessions``         snapshot of every tracked session's status
  - ``GET  /sessions/{id}``    one session's current status (404 if untracked)
"""

import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from pydantic import BaseModel

from mission_control.detector.events import SessionState
from mission_control.detector.registry import SessionStatus
from mission_control.server.ingest import IngestService

_MAX_BODY_BYTES = 1 << 20  # 1 MiB — a hook payload is tiny; reject anything huge.


class SessionStateResponse(BaseModel):
    """Wire shape for one session's reconciled state (Pydantic V2, no dicts)."""

    session_id: str
    state: SessionState
    updated_at: str

    @classmethod
    def of(cls, status: SessionStatus) -> "SessionStateResponse":
        """Project a registry :class:`SessionStatus` onto the response model."""
        return cls(
            session_id=status.session_id,
            state=status.state,
            updated_at=status.updated_at.isoformat(),
        )


class SnapshotResponse(BaseModel):
    """Wire shape for the whole-board snapshot (``GET /sessions``)."""

    sessions: list[SessionStateResponse]


class HookEndpoint:
    """A running local HTTP server fronting one shared :class:`IngestService`.

    Construct, call :meth:`start` (background thread) or use as a context
    manager; :attr:`port` is the actually-bound port (pass ``0`` to autobind,
    which the tests use to avoid port clashes).
    """

    def __init__(
        self, service: IngestService | None = None, host: str = "127.0.0.1", port: int = 0
    ) -> None:
        self.service = service or IngestService()
        self._server = ThreadingHTTPServer((host, port), _make_handler(self.service))
        bound_host, bound_port = self._server.server_address[:2]
        self._host = str(bound_host)
        self._port = int(bound_port)

    @property
    def port(self) -> int:
        """The bound TCP port (resolved even when constructed with ``0``)."""
        return self._port

    @property
    def host(self) -> str:
        """The bound host."""
        return self._host

    def serve_forever(self) -> None:
        """Block serving requests (used by the ``__main__`` entrypoint)."""
        self._server.serve_forever()

    def start(self) -> "HookEndpoint":
        """Serve in a daemon thread and return self (so tests can POST to it)."""
        Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def stop(self) -> None:
        """Stop serving and release the socket."""
        self._server.shutdown()
        self._server.server_close()

    def __enter__(self) -> "HookEndpoint":
        return self.start()

    def __exit__(self, *_exc: object) -> None:
        self.stop()


def _make_handler(service: IngestService) -> type[BaseHTTPRequestHandler]:
    """Build a request handler class bound to one ingest service instance."""

    class _Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format: str, *args: object) -> None:
            """Silence the default stderr access log (this is a sidecar)."""

        def do_POST(self) -> None:  # BaseHTTPRequestHandler API (name is mandated).
            if self.path != "/hooks":
                return self._send_error(HTTPStatus.NOT_FOUND, "unknown route")
            payload = self._read_json_body()
            if payload is None:
                return self._send_error(HTTPStatus.BAD_REQUEST, "invalid JSON body")
            status = service.ingest_payload(payload)
            self._send_model(HTTPStatus.OK, SessionStateResponse.of(status))

        def do_GET(self) -> None:  # BaseHTTPRequestHandler API (name is mandated).
            if self.path == "/sessions":
                snapshot = service.snapshot()
                body = SnapshotResponse(
                    sessions=[SessionStateResponse.of(s) for s in snapshot.values()]
                )
                return self._send_model(HTTPStatus.OK, body)
            if self.path.startswith("/sessions/"):
                return self._send_session(self.path.removeprefix("/sessions/"))
            self._send_error(HTTPStatus.NOT_FOUND, "unknown route")

        def _send_session(self, session_id: str) -> None:
            status = service.status_of(session_id)
            if status is None:
                return self._send_error(HTTPStatus.NOT_FOUND, "unknown session")
            self._send_model(HTTPStatus.OK, SessionStateResponse.of(status))

        def _read_json_body(self) -> dict | None:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0 or length > _MAX_BODY_BYTES:
                return None
            try:
                parsed = json.loads(self.rfile.read(length))
            except (json.JSONDecodeError, UnicodeDecodeError):
                return None
            return parsed if isinstance(parsed, dict) else None

        def _send_model(self, status: HTTPStatus, model: BaseModel) -> None:
            self._write(status, model.model_dump_json().encode())

        def _send_error(self, status: HTTPStatus, message: str) -> None:
            self._write(status, json.dumps({"error": message}).encode())

        def _write(self, status: HTTPStatus, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return _Handler


__all__ = [
    "HookEndpoint",
    "SessionStateResponse",
    "SnapshotResponse",
]
