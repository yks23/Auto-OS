#!/usr/bin/env python3
import argparse
import csv
import html
import json
import math
import re
from pathlib import Path


BUILD_START_RE = re.compile(r"===STARRYOS(?:-DEBUG)?-BUILD-START jobs=(\d+) start=(\d+)===")
BUILD_END_RE = re.compile(r"===STARRYOS(?:-DEBUG)?-BUILD-END jobs=(\d+) rc=(\d+) elapsed=(\d+)===")
CARGO_LINE_RE = re.compile(r"^===CARGO-LINE t=(\d+)===\s*(.*)$")
COMPILING_RE = re.compile(r"Compiling\s+([^\s]+)")


def parse_events(path):
    start_epoch = None
    elapsed = None
    jobs = ""
    rc = ""
    events = []
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.rstrip("\n")
            m = BUILD_START_RE.search(line)
            if m:
                jobs = m.group(1)
                start_epoch = int(m.group(2))
                continue
            m = BUILD_END_RE.search(line)
            if m:
                jobs = m.group(1)
                rc = m.group(2)
                elapsed = int(m.group(3))
                continue
            m = CARGO_LINE_RE.match(line)
            if not m:
                continue
            epoch = int(m.group(1))
            payload = m.group(2)
            rel = None if start_epoch is None else max(0, epoch - start_epoch)
            compile_match = COMPILING_RE.search(payload)
            if compile_match:
                events.append({"t": rel, "kind": "compile_start", "name": compile_match.group(1)})
                continue
            if payload.startswith("{"):
                try:
                    obj = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                reason = obj.get("reason")
                if reason == "compiler-artifact":
                    target = obj.get("target") or {}
                    target_kind = ",".join(target.get("kind") or [])
                    events.append(
                        {
                            "t": rel,
                            "kind": "artifact_finish",
                            "name": target.get("name", ""),
                            "target_kind": target_kind,
                            "package_id": obj.get("package_id", ""),
                        }
                    )
                elif reason == "build-script-executed":
                    events.append({"t": rel, "kind": "build_script_executed", "package_id": obj.get("package_id", "")})
                elif reason == "build-finished":
                    events.append({"t": rel, "kind": "build_finished", "success": obj.get("success")})
    if start_epoch is None or elapsed is None:
        raise SystemExit("missing STARRYOS-BUILD start/end markers")
    return {"start_epoch": start_epoch, "elapsed": elapsed, "jobs": jobs, "rc": rc, "events": events}


def bucketize(meta, bucket_sec):
    bucket_count = math.ceil(meta["elapsed"] / bucket_sec)
    buckets = []
    for i in range(bucket_count):
        buckets.append(
            {
                "bucket": i,
                "t_start": i * bucket_sec,
                "t_end": min((i + 1) * bucket_sec, meta["elapsed"]),
                "compile_starts": 0,
                "artifact_finishes": 0,
                "build_scripts": 0,
                "proc_macro_finishes": 0,
                "custom_build_finishes": 0,
                "lib_finishes": 0,
                "bin_finishes": 0,
            }
        )
    for event in meta["events"]:
        if event["t"] is None:
            continue
        idx = min(int(event["t"] // bucket_sec), bucket_count - 1)
        bucket = buckets[idx]
        if event["kind"] == "compile_start":
            bucket["compile_starts"] += 1
        elif event["kind"] == "artifact_finish":
            bucket["artifact_finishes"] += 1
            target_kind = event.get("target_kind", "")
            if "proc-macro" in target_kind:
                bucket["proc_macro_finishes"] += 1
            if "custom-build" in target_kind:
                bucket["custom_build_finishes"] += 1
            if "lib" in target_kind:
                bucket["lib_finishes"] += 1
            if "bin" in target_kind:
                bucket["bin_finishes"] += 1
        elif event["kind"] == "build_script_executed":
            bucket["build_scripts"] += 1
    started = 0
    finished = 0
    for bucket in buckets:
        started += bucket["compile_starts"]
        finished += bucket["artifact_finishes"]
        bucket["cum_starts"] = started
        bucket["cum_finishes"] = finished
        bucket["approx_in_flight"] = max(0, started - finished)
    return buckets


def write_csv(path, buckets):
    fields = [
        "bucket",
        "t_start",
        "t_end",
        "compile_starts",
        "artifact_finishes",
        "build_scripts",
        "proc_macro_finishes",
        "custom_build_finishes",
        "lib_finishes",
        "bin_finishes",
        "cum_starts",
        "cum_finishes",
        "approx_in_flight",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(buckets)


def write_svg(path, buckets, elapsed, title):
    width = 1280
    height = 520
    pad_left = 64
    pad_right = 32
    pad_top = 46
    pad_bottom = 64
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    max_bar = max(max(b["compile_starts"], b["artifact_finishes"], b["build_scripts"]) for b in buckets) if buckets else 1
    max_line = max((b["approx_in_flight"] for b in buckets), default=1)
    max_y = max(1, math.ceil(max(max_bar, max_line) / 10.0) * 10.0)

    def sx(t):
        return pad_left + (t / elapsed) * plot_w if elapsed else pad_left

    def sy(v):
        return pad_top + (1.0 - min(v, max_y) / max_y) * plot_h

    grid = []
    for value in range(0, int(max_y) + 1, max(5, int(max_y // 5))):
        y = sy(value)
        grid.append(f"<line x1='{pad_left}' y1='{y:.2f}' x2='{width - pad_right}' y2='{y:.2f}' stroke='#e5e7eb'/>")
        grid.append(f"<text x='{pad_left - 10}' y='{y + 4:.2f}' text-anchor='end' font-size='12' fill='#475569'>{value}</text>")
    for sec in range(0, elapsed + 1, 60):
        x = sx(sec)
        grid.append(f"<line x1='{x:.2f}' y1='{pad_top}' x2='{x:.2f}' y2='{height - pad_bottom}' stroke='#f1f5f9'/>")
        grid.append(f"<text x='{x:.2f}' y='{height - 24}' text-anchor='middle' font-size='12' fill='#475569'>{sec}s</text>")

    bars = []
    for b in buckets:
        x0 = sx(b["t_start"])
        x1 = sx(b["t_end"])
        bw = max(1, (x1 - x0) / 3.4)
        gap = bw * 0.15
        for offset, key, color in (
            (0, "compile_starts", "#2563eb"),
            (1, "artifact_finishes", "#16a34a"),
            (2, "build_scripts", "#f97316"),
        ):
            value = b[key]
            x = x0 + offset * (bw + gap) + 2
            y = sy(value)
            h = height - pad_bottom - y
            bars.append(f"<rect x='{x:.2f}' y='{y:.2f}' width='{bw:.2f}' height='{h:.2f}' fill='{color}' opacity='0.82'/>")
    points = " ".join(f"{sx((b['t_start'] + b['t_end']) / 2):.2f},{sy(b['approx_in_flight']):.2f}" for b in buckets)
    legend = """
  <rect x="760" y="16" width="12" height="12" fill="#2563eb"/><text x="778" y="27" font-size="12" fill="#334155">compile starts</text>
  <rect x="900" y="16" width="12" height="12" fill="#16a34a"/><text x="918" y="27" font-size="12" fill="#334155">artifact finishes</text>
  <rect x="1056" y="16" width="12" height="12" fill="#f97316"/><text x="1074" y="27" font-size="12" fill="#334155">build scripts</text>
"""
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <text x="{pad_left}" y="28" font-family="Arial, sans-serif" font-size="18" font-weight="700" fill="#0f172a">{html.escape(title)}</text>
  {legend}
  {''.join(grid)}
  <line x1="{pad_left}" y1="{pad_top}" x2="{pad_left}" y2="{height - pad_bottom}" stroke="#334155"/>
  <line x1="{pad_left}" y1="{height - pad_bottom}" x2="{width - pad_right}" y2="{height - pad_bottom}" stroke="#334155"/>
  {''.join(bars)}
  <polyline fill="none" stroke="#111827" stroke-width="2.5" points="{points}"/>
  <text x="{width / 2:.2f}" y="{height - 8}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">build time</text>
  <text transform="translate(18 {height / 2:.2f}) rotate(-90)" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">events per bucket / approximate in-flight</text>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def write_summary(path, meta, buckets):
    total_starts = sum(b["compile_starts"] for b in buckets)
    total_finishes = sum(b["artifact_finishes"] for b in buckets)
    total_scripts = sum(b["build_scripts"] for b in buckets)
    peak_start = max(buckets, key=lambda b: b["compile_starts"])
    peak_finish = max(buckets, key=lambda b: b["artifact_finishes"])
    tail = [b for b in buckets if b["t_start"] >= max(0, meta["elapsed"] - 120)]
    tail_starts = sum(b["compile_starts"] for b in tail)
    tail_finishes = sum(b["artifact_finishes"] for b in tail)
    lines = [
        "# Cargo Build Timeline Summary",
        "",
        f"- elapsed_s: `{meta['elapsed']}`",
        f"- jobs: `{meta['jobs']}`",
        f"- rc: `{meta['rc']}`",
        f"- total_compile_starts: `{total_starts}`",
        f"- total_artifact_finishes: `{total_finishes}`",
        f"- total_build_script_executed: `{total_scripts}`",
        f"- peak_compile_start_bucket: `{peak_start['t_start']}-{peak_start['t_end']}s`, starts `{peak_start['compile_starts']}`",
        f"- peak_artifact_finish_bucket: `{peak_finish['t_start']}-{peak_finish['t_end']}s`, finishes `{peak_finish['artifact_finishes']}`",
        f"- final_120s_compile_starts: `{tail_starts}`",
        f"- final_120s_artifact_finishes: `{tail_finishes}`",
        "",
        "## Bucket Table",
        "",
        "| Time | Starts | Finishes | Build scripts | Approx in-flight |",
        "|---:|---:|---:|---:|---:|",
    ]
    for b in buckets:
        lines.append(
            f"| {b['t_start']}-{b['t_end']}s | {b['compile_starts']} | {b['artifact_finishes']} | {b['build_scripts']} | {b['approx_in_flight']} |"
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Analyze timestamped Cargo build log by time buckets.")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--bucket-sec", type=int, default=30)
    parser.add_argument("--out-prefix", required=True, type=Path)
    args = parser.parse_args()

    meta = parse_events(args.log)
    buckets = bucketize(meta, args.bucket_sec)
    args.out_prefix.parent.mkdir(parents=True, exist_ok=True)
    out_csv = args.out_prefix.with_suffix(".timeline.csv")
    out_svg = args.out_prefix.with_suffix(".timeline.svg")
    out_summary = args.out_prefix.with_suffix(".timeline.md")
    write_csv(out_csv, buckets)
    write_svg(out_svg, buckets, meta["elapsed"], f"Cargo timeline, SMP8/jobs=8, bucket={args.bucket_sec}s")
    write_summary(out_summary, meta, buckets)
    print(f"csv={out_csv}")
    print(f"svg={out_svg}")
    print(f"summary={out_summary}")


if __name__ == "__main__":
    main()
