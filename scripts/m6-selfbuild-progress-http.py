#!/usr/bin/env python3
"""Localhost HTTP viewer for M6 guest selfbuild serial log (server: stdlib only).

Browser page loads Chart.js from jsDelivr CDN for the syscall delta bar chart.

**数据来源（真实含义）**：syscall 曲线与 stall_hint 仅当 **M6_PROGRESS_LOG 指向的串口文件里**
出现访客内核 dump 的 `===SYSCALL_STATS_*===` 块时才有意义；这些块须来自 **Starry 访客内**
可读 `/proc/syscall_stats` 的内核。宿主 strace、verify-syscall-monitor-smoke 假日志等**不是**访客真实 cargo。

Environment:
  M6_PROGRESS_BIND  default 127.0.0.1
  M6_PROGRESS_PORT  default 8765
  M6_PROGRESS_LOG   default .guest-runs/riscv64-m6/results.txt (relative to cwd)
  M6_CARGO_PTY      read by /api/status for note text (default 0 in guest scripts)
  M6_SYSCALL_STATS_INTERVAL_SEC  default 10; hint for UI rate = Δcount / (Δt×hint); must match guest watcher interval;
  guest kernel must expose /proc/syscall_stats for syscall dumps in the serial log.
"""

from __future__ import annotations

import errno
import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_LOG = ".guest-runs/riscv64-m6/results.txt"
TAIL_BYTES = 256 * 1024
STATUS_TAIL_BYTES = 512 * 1024
API_MAX_LINES = 400
HTML_MAX_LINES = 200
STATUS_MARKER_LINES = 8
COMPILING_NEEDLE = "compiling "
MARKER_PATTERN = re.compile(r"(\[M6|SELFBUILD|error:|panic|Finished)", re.IGNORECASE)

SYSCALL_BEGIN = "===SYSCALL_STATS_BEGIN==="
SYSCALL_END = "===SYSCALL_STATS_END==="
# bench / evidence 脚本常用 AFTER 块（与 BEGIN/END 内容格式相同）
SYSCALL_AFTER_BEGIN = "===SYSCALL_STATS_AFTER_BEGIN==="
SYSCALL_AFTER_END = "===SYSCALL_STATS_AFTER_END==="
# guest-onecrate-inner.sh 长 cargo/rustc 阶段周期性 dump（与 M6 块内容格式相同）
ONECRATE_SYSCALL_BEGIN = "===ONECRATE_SYSCALL_STATS_BEGIN==="
ONECRATE_SYSCALL_END = "===ONECRATE_SYSCALL_STATS_END==="
# 解析 syscall 快照：日志可能很大，只扫尾部（足够覆盖最近若干次 dump）。
SYSCALL_PARSE_MAX_BYTES = 64 * 1024 * 1024
_SYSCALL_LINE_RE = re.compile(r"^\s*(\d+)\s+(\d+)\s*$")


def log_path() -> str:
    return os.environ.get("M6_PROGRESS_LOG", DEFAULT_LOG)


def read_tail_text(path: str, max_bytes: int, max_lines: int | None) -> str:
    start = 0
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = max(0, size - max_bytes)
            f.seek(start)
            data = f.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    if not max_lines:
        return text
    lines = text.splitlines(keepends=True)
    if start > 0 and lines:
        lines = lines[1:]
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    return "".join(lines)


def read_tail_raw(path: str, max_bytes: int) -> tuple[int, bytes]:
    """Return (start_offset, raw bytes from tail). On error: (0, b'')."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = max(0, size - max_bytes)
            f.seek(start)
            data = f.read()
            return start, data
    except OSError:
        return 0, b""


def read_text_tail_for_syscall_parse(path: str, max_bytes: int = SYSCALL_PARSE_MAX_BYTES) -> str:
    """Read tail of log for syscall block scanning (UTF-8, replace errors)."""
    try:
        st = os.stat(path)
    except OSError:
        return ""
    size = int(st.st_size)
    if size <= 0:
        return ""
    start = 0
    try:
        with open(path, "rb") as f:
            if size > max_bytes:
                start = size - max_bytes
                f.seek(start)
            data = f.read()
    except OSError:
        return ""
    text = data.decode("utf-8", errors="replace")
    if start > 0 and text:
        nl = text.find("\n")
        if nl != -1:
            text = text[nl + 1 :]
    return text


def parse_syscall_snapshot_block(lines: list[str]) -> dict[int, int]:
    """Parse `nr count` lines; skip header/total/non-matching."""
    counts: dict[int, int] = {}
    for ln in lines:
        s = ln.strip()
        if not s or s.lower().startswith("total"):
            continue
        m = _SYSCALL_LINE_RE.match(ln.rstrip("\n"))
        if not m:
            continue
        nr = int(m.group(1))
        c = int(m.group(2))
        counts[nr] = c
    return counts


def extract_syscall_snapshots(text: str) -> list[dict[int, int]]:
    """Return ordered list of per-snapshot count maps from BEGIN/END or AFTER_* blocks."""
    out: list[dict[int, int]] = []
    i = 0
    lines = text.splitlines()
    n = len(lines)
    while i < n:
        stripped = lines[i].strip()
        if stripped == SYSCALL_BEGIN:
            end_marker = SYSCALL_END
        elif stripped == SYSCALL_AFTER_BEGIN:
            end_marker = SYSCALL_AFTER_END
        elif stripped == ONECRATE_SYSCALL_BEGIN:
            end_marker = ONECRATE_SYSCALL_END
        else:
            i += 1
            continue
        i += 1
        chunk: list[str] = []
        while i < n and lines[i].strip() != end_marker:
            chunk.append(lines[i])
            i += 1
        if i < n and lines[i].strip() == end_marker:
            out.append(parse_syscall_snapshot_block(chunk))
            i += 1
        else:
            break
    return out


def syscall_interval_hint_sec() -> int:
    raw = os.environ.get("M6_SYSCALL_STATS_INTERVAL_SEC", "10").strip()
    try:
        n = int(raw)
    except ValueError:
        return 10
    return n if n >= 1 else 1


def build_syscall_series_payload(snapshots: list[dict[int, int]], truncated_scan: bool) -> dict:
    """One point per BEGIN/END block: monotonic index as t, totals and per-nr counts."""
    series: list[dict] = []
    for i, counts in enumerate(snapshots):
        total = int(sum(counts.values()))
        by_nr = {str(k): int(v) for k, v in sorted(counts.items())}
        series.append({"t": float(i), "total": total, "by_nr": by_nr})
    stall_hint = False
    if len(series) >= 3:
        t_last = int(series[-1]["total"])
        t_prev = int(series[-2]["total"])
        stall_hint = t_last == t_prev and t_last > 0
    return {
        "series": series,
        "stall_hint": stall_hint,
        "interval_hint_sec": syscall_interval_hint_sec(),
        "truncated_scan": truncated_scan,
        "snapshots": len(series),
        "server_time_unix": time.time(),
    }


def syscall_series_from_log_path(path: str) -> dict:
    st_size = 0
    truncated_scan = False
    try:
        st_size = int(os.stat(path).st_size)
    except OSError:
        pass
    text = read_text_tail_for_syscall_parse(path)
    if st_size > SYSCALL_PARSE_MAX_BYTES and text:
        truncated_scan = True
    snaps = extract_syscall_snapshots(text)
    return build_syscall_series_payload(snaps, truncated_scan)


def build_syscall_delta_payload(snapshots: list[dict[int, int]], truncated_scan: bool) -> dict:
    """Top 40 positive deltas between last two snapshots."""
    n = len(snapshots)
    if n < 2:
        note = "等待访客内至少两次 dump…"
        if truncated_scan:
            note += "（当前仅扫描日志尾部，若快照均在更早位置可增大 SYSCALL_PARSE_MAX_BYTES）"
        return {
            "snapshots": n,
            "labels": [],
            "values": [],
            "note": note,
        }
    s1, s2 = snapshots[-2], snapshots[-1]
    keys = set(s1) | set(s2)
    deltas: list[tuple[int, int]] = []
    for k in keys:
        d = s2.get(k, 0) - s1.get(k, 0)
        if d > 0:
            deltas.append((k, d))
    deltas.sort(key=lambda x: -x[1])
    top = deltas[:40]
    labels = [str(nr) for nr, _ in top]
    values = [v for _, v in top]
    note = f"相邻两次 dump 正增量 top {len(top)}（全文件扫描区域内共 {n} 个快照）。"
    if truncated_scan:
        note += " 仅解析日志尾部一段；更早快照未计入 N。"
    return {
        "snapshots": n,
        "labels": labels,
        "values": values,
        "note": note,
    }


def syscall_delta_from_log_path(path: str) -> dict:
    st_size = 0
    truncated_scan = False
    try:
        st_size = int(os.stat(path).st_size)
    except OSError:
        pass
    text = read_text_tail_for_syscall_parse(path)
    if st_size > SYSCALL_PARSE_MAX_BYTES and text:
        truncated_scan = True
    snaps = extract_syscall_snapshots(text)
    return build_syscall_delta_payload(snaps, truncated_scan)


def analyze_status_tail(raw: bytes) -> tuple[int, int, list[str]]:
    """line_count, compiling_hits, m6_markers (last matches in order)."""
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()
    line_count = len(lines)
    compiling_hits = sum(1 for ln in lines if COMPILING_NEEDLE in ln.lower())
    hits: list[str] = []
    for ln in lines:
        if MARKER_PATTERN.search(ln):
            hits.append(ln)
    if len(hits) > STATUS_MARKER_LINES:
        hits = hits[-STATUS_MARKER_LINES:]
    return line_count, compiling_hits, hits


class M6ProgressServer(ThreadingHTTPServer):
    """Tracks log file size changes in memory for staleness_sec (thread-safe)."""

    def __init__(self, server_address, RequestHandlerClass, bind_and_activate=True):
        super().__init__(server_address, RequestHandlerClass, bind_and_activate)
        self._status_lock = threading.Lock()
        self._last_size: int | None = None
        self._last_size_change_mono: float | None = None


INDEX_HTML = """<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>M6 selfbuild log</title>
<style>
body {{ font-family: system-ui, sans-serif; margin: 1rem; }}
#status {{ font-size: 0.9rem; background: #1a1a2e; color: #e0e0e0; padding: 0.75rem 1rem; border-radius: 6px; margin-bottom: 1rem; line-height: 1.5; }}
#status .label {{ color: #888; }}
#status .warn {{ color: #f5a623; margin-top: 0.5rem; }}
#stall-banner {{ display: none; background: #fff8e1; color: #7a5d00; border: 1px solid #e6c200; padding: 0.65rem 1rem; border-radius: 6px; margin-bottom: 1rem; font-size: 0.95rem; line-height: 1.45; }}
#stall-banner.visible {{ display: block; }}
#syscall-panel {{ margin: 1.25rem 0; padding: 1rem; background: #f6f7fb; border-radius: 8px; border: 1px solid #dde1ea; }}
#syscall-panel h2 {{ font-size: 1.05rem; margin: 0 0 0.5rem 0; }}
#syscall-note {{ font-size: 0.85rem; color: #444; margin-bottom: 0.75rem; }}
#syscall-canvas-wrap {{ position: relative; height: min(70vh, 520px); max-width: 100%; }}
#syscall-series-wrap {{ position: relative; height: min(55vh, 420px); max-width: 100%; margin-top: 0.5rem; }}
pre {{ background: #111; color: #eee; padding: 1rem; overflow: auto; white-space: pre-wrap; word-break: break-word; }}
.note {{ color: #555; font-size: 0.9rem; margin-top: 0.5rem; }}
</style>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
</head>
<body>
<h1>M6 guest selfbuild progress</h1>
<div id="status">Loading status…</div>
<div id="stall-banner" role="status"></div>
<p>Log file: <code id="logpath"></code></p>
<div id="syscall-panel">
<h2>Syscall 增量（相邻两次 DUMP 之差）</h2>
<div id="syscall-note">Loading…</div>
<div id="syscall-canvas-wrap"><canvas id="syscallCanvas"></canvas></div>
<h2 style="margin-top:1.25rem;font-size:1.05rem;">Syscall 序列（总次数 + 最近区间 top5 速率）</h2>
<div id="syscall-series-note" class="note">Loading…</div>
<div id="syscall-series-wrap"><canvas id="syscallSeriesCanvas"></canvas></div>
</div>
<pre id="log">Loading…</pre>
<p class="note">Run <code>bash scripts/demo-m6-selfbuild.sh</code> (or QEMU) in another terminal. Log + status refresh every 3s; syscall charts poll every 2s. Set <code>M6_SYSCALL_STATS_INTERVAL_SEC</code> the same on host (this server) and guest so rates match; the guest kernel must expose <code>/proc/syscall_stats</code>.</p>
<script>
const LOGPATH = {logpath_js};
const MAX_LINES = {max_lines};
let prevBytes = null;
let syscallChart = null;
let syscallSeriesChart = null;
const RATE_COLORS = [
  'rgba(255, 99, 132, 0.85)',
  'rgba(75, 192, 192, 0.85)',
  'rgba(255, 206, 86, 0.9)',
  'rgba(153, 102, 255, 0.85)',
  'rgba(201, 203, 207, 0.9)',
];
function esc(s) {{
  const d = document.createElement('div');
  d.textContent = s;
  return d.innerHTML;
}}
function fmtDelta(b) {{
  if (b === null || b === undefined) return '—';
  if (b === 0) return '0';
  const sign = b > 0 ? '+' : '';
  return sign + b;
}}
const STALL_BANNER_TEXT = 'Syscall total flat over recent snapshots (~2 intervals with no new syscalls). See guest heartbeat / cargo buffer (e.g. M6_CARGO_PTY).';
function setStallBanner(on) {{
  const b = document.getElementById('stall-banner');
  if (!b) return;
  if (on) {{
    b.textContent = STALL_BANNER_TEXT;
    b.classList.add('visible');
  }} else {{
    b.textContent = '';
    b.classList.remove('visible');
  }}
}}
async function loadLog() {{
  const pre = document.getElementById('log');
  try {{
    const r = await fetch('/api/log', {{ cache: 'no-store' }});
    const t = await r.text();
    const lines = t.split(/\\r?\\n/);
    const tail = lines.slice(-MAX_LINES).join('\\n');
    pre.innerHTML = esc(tail || '(empty)');
  }} catch (e) {{
    pre.textContent = 'Error: ' + e;
  }}
}}
async function loadStatus() {{
  const el = document.getElementById('status');
  try {{
    const r = await fetch('/api/status', {{ cache: 'no-store' }});
    const j = await r.json();
    const bytes = j.log_bytes ?? 0;
    const d = prevBytes === null ? null : bytes - prevBytes;
    prevBytes = bytes;
    const stale = j.staleness_sec === null || j.staleness_sec === undefined
      ? '—' : String(Math.floor(Number(j.staleness_sec)));
    const lastMarker = (j.m6_markers && j.m6_markers.length)
      ? j.m6_markers[j.m6_markers.length - 1] : '(none)';
    const exists = j.log_exists !== false;
    const parts = [
      '<span class="label">bytes</span> ' + bytes + ' &nbsp;|&nbsp; <span class="label">Δbytes</span> ' + fmtDelta(d),
      '<span class="label">staleness_sec</span> ' + stale,
      '<span class="label">compiling_hits</span> (tail) ' + (j.compiling_hits ?? 0),
      '<span class="label">lines</span> (tail) ' + (j.line_count ?? 0),
      '<span class="label">last marker</span> ' + esc(lastMarker.slice(0, 500)),
    ];
    if (!exists) parts.unshift('<span class="label">log</span> missing');
    let html = parts.join('<br>');
    if (j.note) html += '<div class="warn">' + esc(j.note) + '</div>';
    el.innerHTML = html;
  }} catch (e) {{
    el.textContent = 'Status error: ' + e;
  }}
}}
function segDt(series, i, hint) {{
  if (i < 1) return hint;
  const dt = (series[i].t - series[i - 1].t) * hint;
  return dt > 0 ? dt : hint;
}}
function top5NrsFromLastDelta(series) {{
  const n = series.length;
  if (n < 2) return [];
  const a = series[n - 2].by_nr || {{}};
  const b = series[n - 1].by_nr || {{}};
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const deltas = [];
  for (const k of keys) {{
    const dv = (Number(b[k]) || 0) - (Number(a[k]) || 0);
    if (dv > 0) deltas.push([k, dv]);
  }}
  deltas.sort((x, y) => y[1] - x[1]);
  return deltas.slice(0, 5).map((x) => x[0]);
}}
function buildSeriesChartConfig(series, hint) {{
  const labels = series.map((p) => String(p.t));
  const totals = series.map((p) => p.total);
  const top5 = top5NrsFromLastDelta(series);
  const rateSets = top5.map((nr, idx) => {{
    const data = [];
    for (let i = 0; i < series.length; i++) {{
      if (i === 0) {{ data.push(null); continue; }}
      const p0 = Number((series[i - 1].by_nr || {{}})[nr]) || 0;
      const p1 = Number((series[i].by_nr || {{}})[nr]) || 0;
      const dt = segDt(series, i, hint);
      data.push((p1 - p0) / dt);
    }}
    return {{
      label: 'nr ' + nr + ' /s',
      data,
      yAxisID: 'y1',
      borderColor: RATE_COLORS[idx % RATE_COLORS.length],
      backgroundColor: 'transparent',
      tension: 0.15,
      pointRadius: 2,
    }};
  }});
  return {{
    data: {{
      labels,
      datasets: [
        {{
          label: 'total syscalls',
          data: totals,
          yAxisID: 'y',
          borderColor: 'rgba(54, 162, 235, 0.95)',
          backgroundColor: 'rgba(54, 162, 235, 0.15)',
          fill: false,
          tension: 0.1,
        }},
        ...rateSets,
      ],
    }},
    options: {{
      responsive: true,
      maintainAspectRatio: false,
      interaction: {{ mode: 'index', intersect: false }},
      scales: {{
        y: {{
          type: 'linear',
          display: true,
          position: 'left',
          title: {{ display: true, text: 'cumulative total' }},
        }},
        y1: {{
          type: 'linear',
          display: top5.length > 0,
          position: 'right',
          grid: {{ drawOnChartArea: false }},
          title: {{ display: true, text: 'Δ/interval / sec (hint)' }},
        }},
      }},
    }},
  }};
}}
async function loadSyscallSeries() {{
  const noteEl = document.getElementById('syscall-series-note');
  const canvas = document.getElementById('syscallSeriesCanvas');
  if (typeof Chart === 'undefined') {{
    noteEl.textContent = 'Chart.js 未加载。';
    return;
  }}
  try {{
    const r = await fetch('/api/syscall_series', {{ cache: 'no-store' }});
    const j = await r.json();
    const series = j.series || [];
    const hint = Number(j.interval_hint_sec) || 10;
    setStallBanner(!!j.stall_hint);
    let note = '快照数 ' + (j.snapshots || 0) + '，interval_hint_sec=' + hint;
    if (j.stall_hint) note += ' · stall_hint';
    if (j.truncated_scan) note += '（仅解析日志尾部，更早 dump 可能未计入）';
    noteEl.textContent = note;
    const ctx = canvas.getContext('2d');
    if (!series.length) {{
      if (syscallSeriesChart) {{ syscallSeriesChart.destroy(); syscallSeriesChart = null; }}
      if (ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
      return;
    }}
    const cfg = buildSeriesChartConfig(series, hint);
    if (syscallSeriesChart) syscallSeriesChart.destroy();
    syscallSeriesChart = new Chart(ctx, {{ type: 'line', ...cfg }});
  }} catch (e) {{
    noteEl.textContent = 'syscall_series error: ' + e;
    setStallBanner(false);
  }}
}}
async function loadSyscallDelta() {{
  const noteEl = document.getElementById('syscall-note');
  const canvas = document.getElementById('syscallCanvas');
  if (typeof Chart === 'undefined') {{
    noteEl.textContent = 'Chart.js 未能从 CDN 加载（检查网络）。';
    return;
  }}
  try {{
    const r = await fetch('/api/syscall_delta', {{ cache: 'no-store' }});
    const j = await r.json();
    noteEl.textContent = j.note || '';
    const labels = j.labels || [];
    const values = j.values || [];
    if (!labels.length) {{
      if (syscallChart) {{ syscallChart.destroy(); syscallChart = null; }}
      const ctx = canvas.getContext('2d');
      if (ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
      return;
    }}
    const ctx = canvas.getContext('2d');
    if (syscallChart) syscallChart.destroy();
    syscallChart = new Chart(ctx, {{
      type: 'bar',
      data: {{
        labels: labels,
        datasets: [{{
          label: 'Δ count',
          data: values,
          backgroundColor: 'rgba(54, 162, 235, 0.65)',
        }}],
      }},
      options: {{
        indexAxis: 'y',
        responsive: true,
        maintainAspectRatio: false,
        plugins: {{ legend: {{ display: false }} }},
        scales: {{
          x: {{ beginAtZero: true }},
        }},
      }},
    }});
  }} catch (e) {{
    noteEl.textContent = 'Syscall API error: ' + e;
  }}
}}
document.getElementById('logpath').textContent = LOGPATH;
loadLog();
loadStatus();
loadSyscallDelta();
loadSyscallSeries();
setInterval(loadLog, 3000);
setInterval(loadStatus, 3000);
setInterval(loadSyscallDelta, 2000);
setInterval(loadSyscallSeries, 2000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "M6ProgressHTTP/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _route_path(self) -> str:
        parsed = urlparse(self.path)
        p = parsed.path.rstrip("/") or "/"
        return p if p != "" else "/"

    def _send_health(self) -> None:
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _staleness_update(self, exists: bool, size: int) -> float | None:
        srv = self.server
        if not isinstance(srv, M6ProgressServer):
            return None
        now = time.monotonic()
        with srv._status_lock:
            if not exists:
                srv._last_size = None
                srv._last_size_change_mono = None
                return None
            if srv._last_size is None or size != srv._last_size:
                srv._last_size = size
                srv._last_size_change_mono = now
            last_mono = srv._last_size_change_mono
        if last_mono is None:
            return None
        return max(0.0, now - last_mono)

    def _send_api_status(self) -> None:
        lp = log_path()
        abs_lp = os.path.abspath(lp)
        note = ""
        if os.environ.get("M6_CARGO_PTY", "0").strip() in ("", "0"):
            note = (
                "M6_CARGO_PTY=0: cargo may fully-buffer stdout; stale log size ≠ guest stuck."
            )

        try:
            st = os.stat(lp)
        except OSError:
            payload = {
                "log_path": abs_lp,
                "log_exists": False,
                "log_bytes": 0,
                "log_mtime_iso": "",
                "line_count": 0,
                "compiling_hits": 0,
                "m6_markers": [],
                "staleness_sec": None,
                "note": note,
            }
            self._staleness_update(False, 0)
        else:
            size = int(st.st_size)
            mtime_iso = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat()
            _, raw = read_tail_raw(lp, STATUS_TAIL_BYTES)
            line_count, compiling_hits, markers = analyze_status_tail(raw)
            stale = self._staleness_update(True, size)
            payload = {
                "log_path": abs_lp,
                "log_exists": True,
                "log_bytes": size,
                "log_mtime_iso": mtime_iso,
                "line_count": line_count,
                "compiling_hits": compiling_hits,
                "m6_markers": markers,
                "staleness_sec": stale,
                "note": note,
            }

        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_api_log(self) -> None:
        lp = log_path()
        text = read_tail_text(lp, TAIL_BYTES, API_MAX_LINES)
        body = text.encode("utf-8", errors="replace")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_api_syscall_delta(self) -> None:
        lp = log_path()
        payload = syscall_delta_from_log_path(lp)
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_api_syscall_series(self) -> None:
        lp = log_path()
        payload = syscall_series_from_log_path(lp)
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_api_syscall_latest(self) -> None:
        lp = log_path()
        full = syscall_series_from_log_path(lp)
        series = full.get("series") or []
        latest = series[-1] if series else None
        payload = {
            "latest": latest,
            "index": len(series) - 1 if series else None,
            "interval_hint_sec": full.get("interval_hint_sec"),
            "truncated_scan": full.get("truncated_scan"),
            "snapshots": full.get("snapshots"),
            "server_time_unix": time.time(),
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_index(self) -> None:
        lp = log_path()
        logpath_js = json.dumps(os.path.abspath(lp))
        page = INDEX_HTML.format(logpath_js=logpath_js, max_lines=HTML_MAX_LINES)
        body = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:
        self._dispatch()

    def do_HEAD(self) -> None:
        self._dispatch()

    def _dispatch(self) -> None:
        path = self._route_path()
        if path == "/health":
            self._send_health()
        elif path == "/api/log":
            self._send_api_log()
        elif path == "/api/status":
            self._send_api_status()
        elif path == "/api/syscall_delta":
            self._send_api_syscall_delta()
        elif path == "/api/syscall_series":
            self._send_api_syscall_series()
        elif path == "/api/syscall_latest":
            self._send_api_syscall_latest()
        elif path == "/":
            self._send_index()
        else:
            self.send_error(404, "Not Found")


def main() -> int:
    bind = os.environ.get("M6_PROGRESS_BIND", DEFAULT_BIND)
    port_s = os.environ.get("M6_PROGRESS_PORT", str(DEFAULT_PORT))
    try:
        port = int(port_s)
    except ValueError:
        print("Invalid M6_PROGRESS_PORT:", port_s, file=sys.stderr)
        return 1

    lp = log_path()
    abs_lp = os.path.abspath(lp)

    origin = port
    server: M6ProgressServer | None = None
    for _ in range(64):
        try:
            server = M6ProgressServer((bind, port), Handler)
            break
        except OSError as e:
            in_use = e.errno == errno.EADDRINUSE or getattr(e, "winerror", None) == 10048
            if not in_use:
                raise
            if port != origin:
                pass
            else:
                print(
                    f"Port {port} in use — trying next (set M6_PROGRESS_PORT to pin).",
                    file=sys.stderr,
                )
            port += 1
    if server is None:
        print(f"No free TCP port in [{origin}, {origin + 63}] on {bind}", file=sys.stderr)
        return 1
    if port != origin:
        print(f"Bound to {bind}:{port} (requested {origin} was busy).", file=sys.stderr)

    print(f"M6 progress HTTP: http://{bind}:{port}/", file=sys.stderr)
    print(f"Log: {abs_lp}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
