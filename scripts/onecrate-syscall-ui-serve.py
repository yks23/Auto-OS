#!/usr/bin/env python3
"""Serve scripts/onecrate-syscall-chart.html and sibling static files on localhost (stdlib only)."""
from __future__ import annotations

import argparse
import http.server
import socketserver
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PORT = 8766


class OnecrateSyscallUIHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SCRIPT_DIR), **kwargs)

    def do_GET(self) -> None:  # noqa: N802 — stdlib API
        raw = self.path.split("?", 1)[0].split("#", 1)[0]
        if raw in ("", "/"):
            self.path = "/onecrate-syscall-chart.html"
        return super().do_GET()


def main() -> int:
    p = argparse.ArgumentParser(description="HTTP server for onecrate syscall chart UI.")
    p.add_argument(
        "port",
        nargs="?",
        type=int,
        default=DEFAULT_PORT,
        help=f"listen port (default {DEFAULT_PORT})",
    )
    args = p.parse_args()
    port = args.port
    if not (1 <= port <= 65535):
        print("port must be 1..65535", file=sys.stderr)
        return 2

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), OnecrateSyscallUIHandler) as httpd:
        url = f"http://127.0.0.1:{port}/"
        print(f"Serving directory: {SCRIPT_DIR}")
        print(f"Open in browser: {url}")
        print("Press Ctrl+C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nStopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
