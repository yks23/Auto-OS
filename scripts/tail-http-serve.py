#!/usr/bin/env python3
"""Serve the tail of a log file over HTTP (stdlib only).

CLI: python3 tail-http-serve.py PATH [PORT] [LINES] [REFRESH_SEC]
  Defaults: PORT=13888, LINES=200, REFRESH_SEC=3

Bind: 127.0.0.1 by default. Set TAIL_HTTP_BIND=0.0.0.0 to listen on all
interfaces (exposes the tail to your LAN; only use on trusted networks).

Endpoints:
  GET /       — HTML with escaped tail + meta refresh
  GET /raw    — plain text tail (curl-friendly)
  GET /health — "ok" newline
"""

from __future__ import annotations

import html
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import List

DEFAULT_PORT = 13888
DEFAULT_LINES = 200
DEFAULT_REFRESH_SEC = 3
TAIL_CHUNK_BYTES = 256 * 1024


def _parse_int(name: str, value: str, minimum: int) -> int:
    try:
        n = int(value)
    except ValueError as e:
        raise SystemExit(f"{name} must be an integer, got {value!r}") from e
    if n < minimum:
        raise SystemExit(f"{name} must be >= {minimum}, got {n}")
    return n


def tail_lines(path: str, max_lines: int, chunk_bytes: int = TAIL_CHUNK_BYTES) -> List[str]:
    """Return up to the last max_lines lines of path, reading from the end for large files."""
    if max_lines <= 0:
        return []
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            if size == 0:
                return []
            if size <= chunk_bytes:
                f.seek(0, os.SEEK_SET)
                data = f.read()
            else:
                f.seek(size - chunk_bytes, os.SEEK_SET)
                data = f.read()
    except OSError as e:
        return [f"read error: {e!s}"] if max_lines else []

    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if size > chunk_bytes and lines:
        lines = lines[1:]
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    return lines


def build_handler(
    path: str,
    max_lines: int,
    refresh_sec: int,
):
    class TailHTTPRequestHandler(BaseHTTPRequestHandler):
        server_version = "TailHTTP/1.0"
        path_arg = path
        max_lines_arg = max_lines
        refresh_sec_arg = refresh_sec

        def log_message(self, fmt: str, *args) -> None:
            sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), fmt % args))

        def do_GET(self) -> None:
            p = self.path.split("?", 1)[0].rstrip("/") or "/"
            if p == "/health":
                body = b"ok\n"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if p not in ("/", "/raw"):
                self.send_error(404, "Not Found")
                return
            lines = tail_lines(self.path_arg, self.max_lines_arg)
            if p == "/raw":
                text = "\n".join(lines) + ("\n" if lines else "")
                body = text.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            escaped = "\n".join(html.escape(line) for line in lines)
            title = html.escape(self.path_arg)
            r = int(self.refresh_sec_arg)
            page = (
                "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
                f"<title>{title}</title>"
                f'<meta http-equiv="refresh" content="{r}">'
                "</head><body><pre>"
                f"{escaped}"
                "</pre></body></html>\n"
            )
            body = page.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return TailHTTPRequestHandler


def main() -> None:
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(
            __doc__.strip()
            + "\n\nExample:\n  python3 scripts/tail-http-serve.py .guest-runs/log/results.txt 13888\n",
            file=sys.stderr,
        )
        raise SystemExit(0 if argv and argv[0] in ("-h", "--help") else 2)

    path = argv[0]
    port = DEFAULT_PORT
    lines = DEFAULT_LINES
    refresh = DEFAULT_REFRESH_SEC
    if len(argv) >= 2:
        port = _parse_int("PORT", argv[1], 1)
    if len(argv) >= 3:
        lines = _parse_int("LINES", argv[2], 1)
    if len(argv) >= 4:
        refresh = _parse_int("REFRESH_SEC", argv[3], 1)
    if len(argv) > 4:
        raise SystemExit("Too many arguments. See --help.")

    bind = os.environ.get("TAIL_HTTP_BIND", "127.0.0.1").strip() or "127.0.0.1"
    if bind == "0.0.0.0":
        sys.stderr.write(
            "TAIL_HTTP_BIND=0.0.0.0: listening on all interfaces; "
            "anyone on the LAN can read this tail — use only on trusted networks.\n"
        )

    handler = build_handler(path, lines, refresh)
    httpd = HTTPServer((bind, port), handler)
    sys.stderr.write(f"Serving tail of {path!r} on http://{bind}:{port}/ (refresh {refresh}s, last {lines} lines)\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("\nShutting down.\n")
        httpd.server_close()


if __name__ == "__main__":
    main()
