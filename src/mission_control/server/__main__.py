"""Run the live hook endpoint as a foreground sidecar process.

    python -m mission_control.server [--host 127.0.0.1] [--port 8787]

Bound to localhost by default (watcher discipline: a local receiver, not a
spawner). Point a Claude Code hook at ``http://127.0.0.1:<port>/hooks``.
"""

import argparse

from mission_control.server.endpoint import HookEndpoint


def main() -> None:
    """Parse args and serve the hook endpoint until interrupted."""
    parser = argparse.ArgumentParser(prog="mission_control.server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    endpoint = HookEndpoint(host=args.host, port=args.port)
    print(f"hook endpoint listening on http://{endpoint.host}:{endpoint.port}/hooks")
    try:
        endpoint.serve_forever()
    except KeyboardInterrupt:
        endpoint.stop()


if __name__ == "__main__":
    main()
