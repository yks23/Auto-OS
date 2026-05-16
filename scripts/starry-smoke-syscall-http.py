#!/usr/bin/env python3
"""HTTP 侧车：实时读 verify-starry-guest-smoke 写入的串口捕获文件，解析 Starry syscall 统计块。

复用 `m6-selfbuild-progress-http.py` 的解析逻辑（`===SYSCALL_STATS_*===`、`===ONECRATE_SYSCALL_STATS_*===`
与 `/proc/syscall_stats` 文本格式一致）。仅标准库；由 `verify-starry-guest-smoke.sh` 或
`guest-onecrate-syscall-evidence.sh` 在 `STARRY_SMOKE_STATS_HTTP` / `GUEST_ONECRATE_STATS_HTTP=1` 时子进程启动。

环境变量：
  STARRY_SMOKE_LOG           必填：串口捕获路径（与 VERIFY_CAPTURE 相同）
  STARRY_SMOKE_STATS_BIND    默认 127.0.0.1（CI 安全；远程看日志请 SSH 隧道或设为 0.0.0.0）
  STARRY_SMOKE_STATS_PORT    默认 1378

  可选：M6_SYSCALL_STATS_INTERVAL_SEC — 传给系列 JSON 的 interval_hint（默认 10）

绑定说明：
  默认只监听本机回环。若在远端 Docker 内跑 verify，可在笔记本执行：
    ssh -N -L 1378:127.0.0.1:1378 user@host
  浏览器打开 http://127.0.0.1:1378/

真实 syscall 数字须来自访客串口中的统计块（见仓库 `.cursor/rules/starry-guest-syscall-real.mdc`）。
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def _load_m6():
    base = Path(__file__).resolve().parent
    p = base / "m6-selfbuild-progress-http.py"
    spec = importlib.util.spec_from_file_location("_starry_smoke_m6_progress", p)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {p}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_M6 = None


def m6():
    global _M6
    if _M6 is None:
        _M6 = _load_m6()
    return _M6


LOG_TAIL_BYTES = 128 * 1024
LOG_TAIL_LINES = 120


def log_abs_path() -> str:
    lp = os.environ.get("STARRY_SMOKE_LOG", "").strip()
    return os.path.abspath(lp) if lp else ""


def ensure_m6_log_env() -> str | None:
    raw = os.environ.get("STARRY_SMOKE_LOG", "").strip()
    if not raw:
        print("starry-smoke-syscall-http: set STARRY_SMOKE_LOG to serial capture path", file=sys.stderr)
        return None
    abs_lp = os.path.abspath(raw)
    os.environ["M6_PROGRESS_LOG"] = abs_lp
    return abs_lp


class Handler(BaseHTTPRequestHandler):
    server_version = "StarrySmokeSyscallHTTP/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _path(self) -> str:
        p = urlparse(self.path).path.rstrip("/") or "/"
        return p

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _stats_payload(self) -> dict:
        mod = m6()
        lp = mod.log_path()
        abs_lp = os.path.abspath(lp)
        meta: dict = {"log_path": abs_lp, "log_exists": False, "log_bytes": 0, "log_mtime_iso": ""}
        try:
            st = os.stat(lp)
        except OSError:
            pass
        else:
            meta["log_exists"] = True
            meta["log_bytes"] = int(st.st_size)
            meta["log_mtime_iso"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))
        series = mod.syscall_series_from_log_path(lp)
        delta = mod.syscall_delta_from_log_path(lp)
        return {
            "meta": meta,
            "syscall_series": series,
            "syscall_delta": delta,
        }

    def _send_stats_json(self) -> None:
        payload = self._stats_payload()
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._send(200, body, "application/json; charset=utf-8")

    def _send_log_tail(self) -> None:
        mod = m6()
        lp = mod.log_path()
        text = mod.read_tail_text(lp, LOG_TAIL_BYTES, LOG_TAIL_LINES)
        self._send(200, text.encode("utf-8", errors="replace"), "text/plain; charset=utf-8")

    def _send_index_html(self) -> None:
        lp = json.dumps(log_abs_path())
        page = f"""<!DOCTYPE html>
<html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Starry smoke syscall stats</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 1rem; line-height: 1.45; }}
pre {{ background: #111; color: #e8e8e8; padding: 0.75rem; overflow: auto; white-space: pre-wrap; word-break: break-word; font-size: 0.85rem; }}
.note {{ color: #555; font-size: 0.9rem; margin-top: 0.75rem; }}
code {{ background: #eee; padding: 0.1em 0.35em; border-radius: 4px; }}
</style></head>
<body>
<h1>Starry guest smoke — syscall stats</h1>
<p>串口捕获: <code id="p"></code> · <a href="/stats.json"><code>/stats.json</code></a> · <a href="/api/log">串口尾</a></p>
<pre id="out">Loading…</pre>
<p class="note">每 2s 拉取 <code>/stats.json</code>。仅当串口中出现 <code>===SYSCALL_STATS_*===</code> 或 <code>===ONECRATE_SYSCALL_STATS_*===</code> 块（访客 <code>/proc/syscall_stats</code>）时 <code>syscall_series</code> 才有快照；普通 smoke 可能无块，属正常。</p>
<script>
document.getElementById('p').textContent = {lp};
async function tick() {{
  const el = document.getElementById('out');
  try {{
    const r = await fetch('/stats.json', {{ cache: 'no-store' }});
    const j = await r.json();
    el.textContent = JSON.stringify(j, null, 2);
  }} catch (e) {{ el.textContent = 'Error: ' + e; }}
}}
tick();
setInterval(tick, 2000);
</script>
</body></html>"""
        self._send(200, page.encode("utf-8"), "text/html; charset=utf-8")

    def do_GET(self) -> None:
        p = self._path()
        if p == "/health":
            self._send(200, b"ok", "text/plain; charset=utf-8")
        elif p == "/stats.json":
            self._send_stats_json()
        elif p == "/api/log":
            self._send_log_tail()
        elif p in ("/", "/index.html"):
            self._send_index_html()
        else:
            self.send_error(404, "Not Found")

    def do_HEAD(self) -> None:
        prev = self.command
        self.command = "HEAD"
        try:
            self.do_GET()
        finally:
            self.command = prev


def main() -> int:
    if ensure_m6_log_env() is None:
        return 1
    bind = os.environ.get("STARRY_SMOKE_STATS_BIND", "127.0.0.1").strip() or "127.0.0.1"
    port_s = os.environ.get("STARRY_SMOKE_STATS_PORT", "1378").strip() or "1378"
    try:
        port = int(port_s)
    except ValueError:
        print("Invalid STARRY_SMOKE_STATS_PORT:", port_s, file=sys.stderr)
        return 1
    # 预加载 m6（校验路径与依赖）
    m6()

    try:
        srv = ThreadingHTTPServer((bind, port), Handler)
    except OSError as e:
        print(f"starry-smoke-syscall-http: cannot bind {bind}:{port}: {e}", file=sys.stderr)
        return 1

    print(f"starry-smoke-syscall-http: http://{bind}:{port}/", file=sys.stderr)
    print(f"  log: {log_abs_path()}", file=sys.stderr)
    if bind == "127.0.0.1":
        print(
            "  (默认仅本机；远程请 SSH 隧道: ssh -N -L 1378:127.0.0.1:1378 user@host "
            "或设 STARRY_SMOKE_STATS_BIND=0.0.0.0)",
            file=sys.stderr,
        )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstarry-smoke-syscall-http: stopped.", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
