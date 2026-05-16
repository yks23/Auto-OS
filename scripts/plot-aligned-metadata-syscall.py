#!/usr/bin/env python3
"""Build Chart.js HTML: host + guest cumulative syscalls vs normalized time (0..1)."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys


def parse_guest_samples(text: str) -> tuple[list[float], list[int]]:
    """Returns (rel_s list, total int list) from ===SYSCALL_SAMPLE rel_s=X total=Y"""
    rel: list[float] = []
    tot: list[int] = []
    for m in re.finditer(r"===SYSCALL_SAMPLE rel_s=(\d+) total=(\d+)", text):
        rel.append(float(m.group(1)))
        tot.append(int(m.group(2)))
    for m in re.finditer(r"===SYSCALL_SAMPLE rel_s=(\d+) total=\?", text):
        rel.append(float(m.group(1)))
        tot.append(0)
    pairs = sorted(zip(rel, tot), key=lambda x: x[0])
    if not pairs:
        return [], []
    rel2 = [p[0] for p in pairs]
    tot2 = [p[1] for p in pairs]
    return rel2, tot2


def norm_cum(cs: list[int]) -> list[float]:
    if not cs:
        return []
    m = max(cs)
    if m <= 0:
        return [0.0] * len(cs)
    return [c / m for c in cs]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--guest-log", required=True, help="guest serial results.txt (strings-friendly)")
    ap.add_argument("--host-json", required=True, help="host-metadata-strace-series.py output")
    ap.add_argument("--out", required=True, help="output .html")
    args = ap.parse_args()

    guest_raw = open(args.guest_log, "rb").read().decode("utf-8", errors="replace")
    g_rel, g_tot = parse_guest_samples(guest_raw)
    if not g_tot:
        print("no guest ===SYSCALL_SAMPLE lines; re-run guest-cargo-syscall-evidence.sh", file=sys.stderr)
        sys.exit(1)

    host = json.load(open(args.host_json, encoding="utf-8"))
    h_ms = host["times_ms"]
    h_cum = host["cumulative_syscalls"]

    g_max_rel = max(max(g_rel) if g_rel else 0.0, 1e-6)
    g_x = [min(r / g_max_rel, 1.0) for r in g_rel]
    g_y = norm_cum(g_tot)
    wall_ms = float(host.get("wall_ms") or 1.0)
    h_x = [min(t / wall_ms, 1.0) for t in h_ms]
    h_y = norm_cum(h_cum)

    title = "Aligned: cargo metadata — cumulative syscalls (Y normalized), time (X normalized)"

    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
body {{ font-family: system-ui, sans-serif; margin: 24px; max-width: 960px; }}
p {{ color: #444; line-height: 1.5; }}
code {{ background: #f2f2f2; padding: 2px 6px; }}
</style></head><body>
<h1>{title}</h1>
<p>
  <strong>对齐协议</strong>：同一命令 <code>cargo metadata --offline --format-version 1 --no-deps</code>；
  访客在 cargo 运行期间周期性读 <code>/proc/syscall_stats</code> 首行 <code>total</code>；
  宿主用 <code>strace -tt -f</code> 按 {host["bucket_ms"]}ms 桶累计行数（带时间戳的 strace 行 ≈ syscall 事件密度）。
  横纵轴均归一化到 0–1，便于比较<strong>形状</strong>；原始峰值：访客 total max = {max(g_tot)}，
  宿主 strace cumulative max = {max(h_cum)}，宿主墙钟 ≈ {host["wall_ms"]:.0f} ms。
</p>
<canvas id="c" height="110"></canvas>
<script>
const gX = {json.dumps(g_x)};
const gY = {json.dumps(g_y)};
const hX = {json.dumps(h_x)};
const hY = {json.dumps(h_y)};
const ctx = document.getElementById('c').getContext('2d');
new Chart(ctx, {{
  type: 'line',
  data: {{
    datasets: [
      {{ label: 'Guest (Starry /proc/syscall_stats, Y norm)', data: gX.map((x,i) => ({{x,y:gY[i]}})), parsing: false, borderColor: '#c62828', tension: 0.15, fill: false }},
      {{ label: 'Host (Linux strace -tt buckets, Y norm)', data: hX.map((x,i) => ({{x,y:hY[i]}})), parsing: false, borderColor: '#1565c0', tension: 0.05, fill: false }},
    ]
  }},
  options: {{
    responsive: true,
    scales: {{
      x: {{
        type: 'linear',
        title: {{ display: true, text: 'Normalized wall time (0=start, 1=end)' }},
        min: 0, max: 1
      }},
      y: {{
        min: 0, max: 1.05,
        title: {{ display: true, text: 'Normalized cumulative syscalls' }}
      }}
    }},
    plugins: {{ legend: {{ position: 'bottom' }} }}
  }}
}});
</script>
</body></html>"""

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
