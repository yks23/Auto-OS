#!/usr/bin/env python3
"""Chart.js: host vs guest for one-crate cargo check; normalized axes + 慢在哪里 分析。"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys


def parse_guest_oncrate(text: str) -> tuple[list[float], list[int]]:
    rel: list[float] = []
    tot: list[int] = []
    for m in re.finditer(r"===ONECRATE_SYSCALL_SAMPLE rel_s=(\d+) total=(\d+)", text):
        rel.append(float(m.group(1)))
        tot.append(int(m.group(2)))
    pairs = sorted(zip(rel, tot), key=lambda x: x[0])
    if not pairs:
        return [], []
    return [p[0] for p in pairs], [p[1] for p in pairs]


def norm_cum(cs: list[int]) -> list[float]:
    if not cs:
        return []
    m = max(cs)
    if m <= 0:
        return [0.0] * len(cs)
    return [c / m for c in cs]


def parse_guest_elapsed(summary_path: str | None) -> float | None:
    if not summary_path or not os.path.isfile(summary_path):
        return None
    t = open(summary_path, encoding="utf-8").read()
    m = re.search(r"elapsed_s:\s*(\d+)", t)
    return float(m.group(1)) if m else None


def analysis_text(guest_s: float | None, host_wall_ms: float, g_tot: list[int], h_cum: list[int]) -> str:
    lines = []
    lines.append("<h2>慢在哪里（启发式）</h2><ul>")
    if guest_s is not None and host_wall_ms > 0:
        ratio = guest_s / (host_wall_ms / 1000.0)
        lines.append(
            f"<li><strong>墙钟比</strong>：访客 ≈ <code>{guest_s:.0f}s</code>，"
            f"宿主（strace 段）≈ <code>{host_wall_ms/1000:.2f}s</code>，"
            f"粗比约 <strong>{ratio:.0f}×</strong>。"
            f"归一化后两条曲线若<strong>形状相近</strong>，主要差在<strong>横轴拉伸</strong>，"
            f"多来自 <strong>QEMU/TCG 指令级模拟</strong>，而不是「Starry syscall 路径完全另一种 workload」。</li>"
        )
    lines.append(
        "<li><strong>Y 轴</strong>：两边累计 syscall 各自除以<strong>本次峰值</strong>，只比「相对爬升」；"
        "绝对次数不可跨内核对比。</li>"
    )
    if g_tot and h_cum:
        g_early = sum(1 for x in g_tot[: max(1, len(g_tot) // 4)] if x < max(g_tot) * 0.1)
        if g_early > len(g_tot) // 2:
            lines.append(
                "<li>若访客<strong>前段长期平坦</strong>：可能是 <strong>rustc 长段计算</strong>（syscall 少）"
                "或 <strong>串口/cargo 缓冲</strong>；对照宿主曲线是否已陡升。</li>"
            )
    lines.append("</ul>")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--guest-log", required=True)
    ap.add_argument("--guest-summary", default="", help="optional summary.txt for elapsed_s")
    ap.add_argument("--host-json", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    guest_raw = open(args.guest_log, "rb").read().decode("utf-8", errors="replace")
    g_rel, g_tot = parse_guest_oncrate(guest_raw)
    if not g_tot:
        print("no ===ONECRATE_SYSCALL_SAMPLE in guest log", file=sys.stderr)
        sys.exit(1)

    host = json.load(open(args.host_json, encoding="utf-8"))
    h_ms = host["times_ms"]
    h_cum = host["cumulative_syscalls"]
    wall_ms = float(host.get("wall_ms") or 1.0)

    g_max_rel = max(max(g_rel) if g_rel else 0.0, 1e-6)
    g_x = [min(r / g_max_rel, 1.0) for r in g_rel]
    g_y = norm_cum(g_tot)
    h_x = [min(t / wall_ms, 1.0) for t in h_ms]
    h_y = norm_cum(h_cum)

    guest_el = parse_guest_elapsed(args.guest_summary or None)
    proto = host.get("protocol", "cargo check …")
    title = "Aligned: single-crate cargo check — normalized cumulative syscalls"

    analysis = analysis_text(guest_el, wall_ms, g_tot, h_cum)

    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
body {{ font-family: system-ui, sans-serif; margin: 24px; max-width: 960px; }}
p, li {{ color: #444; line-height: 1.55; }}
code {{ background: #f2f2f2; padding: 2px 6px; }}
</style></head><body>
<h1>{title}</h1>
<p><strong>命令（宿主 JSON）</strong>：<code>{proto}</code>；宿主 strace 桶 <code>{host["bucket_ms"]}ms</code>，
cargo 退出码 <code>{host.get("cargo_exit", "?")}</code>（124=timeout）。</p>
<p>访客 <code>total</code> 峰值 <code>{max(g_tot)}</code>；宿主 strace 累计峰值 <code>{max(h_cum)}</code>；宿主墙钟约 <code>{wall_ms:.0f}ms</code>。</p>
<canvas id="c" height="120"></canvas>
{analysis}
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
      {{ label: 'Guest (Starry /proc/syscall_stats)', data: gX.map((x,i) => ({{x,y:gY[i]}})), parsing: false, borderColor: '#c62828', tension: 0.12, fill: false }},
      {{ label: 'Host (Linux strace buckets)', data: hX.map((x,i) => ({{x,y:hY[i]}})), parsing: false, borderColor: '#1565c0', tension: 0.05, fill: false }},
    ]
  }},
  options: {{
    responsive: true,
    scales: {{
      x: {{ type: 'linear', title: {{ display: true, text: 'Normalized wall time (0–1)' }}, min: 0, max: 1 }},
      y: {{ min: 0, max: 1.05, title: {{ display: true, text: 'Normalized cumulative syscalls' }} }}
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
