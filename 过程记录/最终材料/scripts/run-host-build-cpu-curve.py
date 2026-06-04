#!/usr/bin/env python3
import argparse
import csv
import html
import math
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path


BUILD_START_RE = re.compile(r"===HOST-ALIGNED-STARRYOS-BUILD-START jobs=(\d+) start=(\d+)===")
BUILD_END_RE = re.compile(
    r"===HOST-ALIGNED-STARRYOS-END jobs=(\d+) rc=(\d+) elapsed=(\d+)(?: end=(\d+))?==="
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run a macOS host StarryOS build and sample its process-tree CPU curve."
    )
    parser.add_argument("--root", default="/Users/txc/code/Auto-OS")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--smp", type=int, default=8)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument(
        "--profile-mode",
        choices=("guest-aligned", "native-release"),
        default="guest-aligned",
        help="guest-aligned keeps the demo overrides; native-release uses the workspace release profile.",
    )
    parser.add_argument(
        "--out-dir",
        default="/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util",
    )
    parser.add_argument("--stamp", default=time.strftime("%Y%m%dT%H%M%S"))
    parser.add_argument(
        "--runner",
        default="/Users/txc/code/Auto-OS/过程记录/最终材料/scripts/run-host-aligned-starryos-oracle.sh",
    )
    return parser.parse_args()


def parse_ps_snapshot():
    proc = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,%cpu=,time=,command="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    rows = {}
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 5)
        if len(parts) < 6:
            continue
        pid_s, ppid_s, pgid_s, cpu_s, cpu_time, command = parts
        try:
            pid = int(pid_s)
            ppid = int(ppid_s)
            pgid = int(pgid_s)
            cpu = float(cpu_s)
        except ValueError:
            continue
        rows[pid] = {
            "ppid": ppid,
            "pgid": pgid,
            "cpu": cpu,
            "cpu_time": cpu_time,
            "command": command,
        }
    return rows


def descendants(snapshot, root_pid):
    children = {}
    for pid, row in snapshot.items():
        children.setdefault(row["ppid"], []).append(pid)

    seen = set()
    stack = [root_pid]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(children.get(pid, []))
    return {pid for pid in seen if pid in snapshot}


def command_kind_counts(rows):
    rustc_count = 0
    cargo_count = 0
    build_script_count = 0
    for row in rows:
        cmd = row["command"]
        if re.search(r"(^|[/ ])rustc($| )", cmd):
            rustc_count += 1
        if re.search(r"(^|[/ ])cargo($| )", cmd):
            cargo_count += 1
        if "build-script-build" in cmd or "/build-script-" in cmd:
            build_script_count += 1
    return rustc_count, cargo_count, build_script_count


def sample_process_tree(root_pid, runner_start_epoch, smp):
    snapshot = parse_ps_snapshot()
    pids = descendants(snapshot, root_pid)
    rows = [snapshot[pid] for pid in sorted(pids)]
    cpu_sum = sum(row["cpu"] for row in rows)
    rustc_count, cargo_count, build_script_count = command_kind_counts(rows)
    top = max(rows, key=lambda row: row["cpu"], default=None)
    epoch = time.time()
    return {
        "epoch": epoch,
        "runner_t_s": epoch - runner_start_epoch,
        "root_pid": root_pid,
        "tree_cpu_pct_sum": cpu_sum,
        "busy_core_equiv": cpu_sum / 100.0,
        "normalized_8core_pct": cpu_sum / smp,
        "process_count": len(rows),
        "rustc_count": rustc_count,
        "cargo_count": cargo_count,
        "build_script_count": build_script_count,
        "max_process_cpu_pct": top["cpu"] if top else 0.0,
        "top_command": top["command"] if top else "",
    }


def write_rows(path, rows, include_build_t=False):
    fields = [
        "epoch",
        "runner_t_s",
    ]
    if include_build_t:
        fields.append("build_t_s")
    fields += [
        "root_pid",
        "tree_cpu_pct_sum",
        "busy_core_equiv",
        "normalized_8core_pct",
        "process_count",
        "rustc_count",
        "cargo_count",
        "build_script_count",
        "max_process_cpu_pct",
        "top_command",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            out = dict(row)
            out["epoch"] = f"{out['epoch']:.3f}"
            out["runner_t_s"] = f"{out['runner_t_s']:.3f}"
            if include_build_t:
                out["build_t_s"] = f"{out['build_t_s']:.3f}"
            for key in (
                "tree_cpu_pct_sum",
                "busy_core_equiv",
                "normalized_8core_pct",
                "max_process_cpu_pct",
            ):
                out[key] = f"{out[key]:.2f}"
            writer.writerow(out)


def read_host_build_meta(log_path):
    meta = {
        "jobs": None,
        "build_start_epoch": None,
        "build_end_epoch": None,
        "build_elapsed_s": None,
        "build_rc": None,
    }
    if not log_path.exists():
        return meta
    with log_path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            start = BUILD_START_RE.search(line)
            if start:
                meta["jobs"] = int(start.group(1))
                meta["build_start_epoch"] = int(start.group(2))
            end = BUILD_END_RE.search(line)
            if end:
                meta["jobs"] = int(end.group(1))
                meta["build_rc"] = int(end.group(2))
                meta["build_elapsed_s"] = int(end.group(3))
                meta["build_end_epoch"] = int(end.group(4)) if end.group(4) else None
    if meta["build_end_epoch"] is None and meta["build_start_epoch"] is not None and meta["build_elapsed_s"] is not None:
        meta["build_end_epoch"] = meta["build_start_epoch"] + meta["build_elapsed_s"]
    return meta


def build_window_rows(raw_rows, meta):
    start = meta.get("build_start_epoch")
    end = meta.get("build_end_epoch")
    if start is None or end is None:
        return []
    rows = []
    for row in raw_rows:
        if start <= row["epoch"] <= end + 0.5:
            out = dict(row)
            out["build_t_s"] = row["epoch"] - start
            rows.append(out)
    return rows


def mean(values):
    return sum(values) / len(values) if values else math.nan


def percentile(values, pct):
    if not values:
        return math.nan
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * pct / 100.0
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] * (hi - pos) + ordered[hi] * (pos - lo)


def fmt(value, digits=1):
    if value is None or math.isnan(value):
        return "n/a"
    return f"{value:.{digits}f}"


def polyline(points):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in points)


def write_svg(path, rows, title, smp):
    width = 980
    height = 420
    left = 68
    right = 24
    top = 46
    bottom = 56
    plot_w = width - left - right
    plot_h = height - top - bottom
    xs = [row["build_t_s"] for row in rows]
    ys = [row["tree_cpu_pct_sum"] for row in rows]
    if not xs or not ys:
        path.write_text("<svg xmlns='http://www.w3.org/2000/svg'></svg>\n", encoding="utf-8")
        return
    x_min = min(xs)
    x_max = max(max(xs), x_min + 1.0)
    y_max = max(800.0, math.ceil(max(ys) / 100.0) * 100.0)
    y_max = max(y_max, max(ys) * 1.10)

    def sx(x):
        return left + ((x - x_min) / (x_max - x_min)) * plot_w

    def sy(y):
        return top + plot_h - (y / y_max) * plot_h

    line_points = [(sx(x), sy(y)) for x, y in zip(xs, ys)]
    rustc_points = [(sx(row["build_t_s"]), sy(row["rustc_count"] * 100.0)) for row in rows]

    grid = []
    y_tick = 0
    while y_tick <= y_max + 0.001:
        y = sy(y_tick)
        grid.append(
            f"<line x1='{left}' y1='{y:.1f}' x2='{width-right}' y2='{y:.1f}' stroke='#e5e7eb'/>"
        )
        grid.append(
            f"<text x='{left-10}' y='{y+4:.1f}' text-anchor='end' font-size='12' fill='#475569'>{int(y_tick)}%</text>"
        )
        y_tick += 100

    x_ticks = []
    tick_step = 10 if x_max <= 80 else 30
    tick = 0
    while tick <= x_max + 0.001:
        x = sx(tick)
        x_ticks.append(
            f"<line x1='{x:.1f}' y1='{top}' x2='{x:.1f}' y2='{height-bottom}' stroke='#f1f5f9'/>"
        )
        x_ticks.append(
            f"<text x='{x:.1f}' y='{height-bottom+24}' text-anchor='middle' font-size='12' fill='#475569'>{int(tick)}s</text>"
        )
        tick += tick_step

    capacity_y = sy(smp * 100.0)
    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <text x="{left}" y="26" font-size="20" font-weight="700" fill="#0f172a">{html.escape(title)}</text>
  {''.join(x_ticks)}
  {''.join(grid)}
  <line x1="{left}" y1="{capacity_y:.1f}" x2="{width-right}" y2="{capacity_y:.1f}" stroke="#dc2626" stroke-width="1.4" stroke-dasharray="6 5"/>
  <text x="{width-right}" y="{capacity_y-8:.1f}" text-anchor="end" font-size="12" fill="#dc2626">8-core full = 800%</text>
  <polyline points="{polyline(rustc_points)}" fill="none" stroke="#94a3b8" stroke-width="1.6" stroke-dasharray="4 4"/>
  <polyline points="{polyline(line_points)}" fill="none" stroke="#2563eb" stroke-width="2.4"/>
  <text x="{left}" y="{height-14}" font-size="12" fill="#475569">x: compile window seconds; blue: process-tree summed %CPU; gray dashed: rustc count x 100</text>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def write_summary(path, rows, meta, log_path, raw_csv, build_csv, svg_path, smp, profile_mode):
    cpu = [row["tree_cpu_pct_sum"] for row in rows]
    busy = [row["busy_core_equiv"] for row in rows]
    normalized = [row["normalized_8core_pct"] for row in rows]
    process_counts = [row["process_count"] for row in rows]
    rustc_counts = [row["rustc_count"] for row in rows]
    lines = [
        "# macOS host StarryOS build CPU curve",
        "",
        f"This is a host-side process-tree `%CPU` sample for the `{profile_mode}` StarryOS build profile.",
        "It includes the build runner's descendant processes, mainly `cargo`, `rustc`, and build scripts.",
        "",
        "## Source",
        "",
        f"- log: `{log_path}`",
        f"- raw process-tree csv: `{raw_csv}`",
        f"- build-window csv: `{build_csv}`",
        f"- svg: `{svg_path}`",
        f"- jobs: `{meta.get('jobs')}`",
        f"- smp config: `{smp}`",
        f"- profile_mode: `{profile_mode}`",
        f"- build_elapsed_s: `{meta.get('build_elapsed_s')}`",
        f"- build_rc: `{meta.get('build_rc')}`",
        "",
        "## CPU utilization",
        "",
        f"- sampled build-window points: `{len(rows)}`",
        f"- mean process-tree CPU: `{fmt(mean(cpu), 1)}%`",
        f"- median process-tree CPU: `{fmt(statistics.median(cpu) if cpu else math.nan, 1)}%`",
        f"- p95 process-tree CPU: `{fmt(percentile(cpu, 95), 1)}%`",
        f"- peak process-tree CPU: `{fmt(max(cpu) if cpu else math.nan, 1)}%`",
        f"- mean busy-core equivalent: `{fmt(mean(busy), 2)}`",
        f"- peak busy-core equivalent: `{fmt(max(busy) if busy else math.nan, 2)}`",
        f"- mean normalized 8-core utilization: `{fmt(mean(normalized), 1)}%`",
        f"- peak normalized 8-core utilization: `{fmt(max(normalized) if normalized else math.nan, 1)}%`",
        f"- seconds >= 400% CPU: `{sum(1 for value in cpu if value >= 400.0)}`",
        f"- seconds >= 600% CPU: `{sum(1 for value in cpu if value >= 600.0)}`",
        f"- seconds >= 700% CPU: `{sum(1 for value in cpu if value >= 700.0)}`",
        f"- peak process count: `{max(process_counts) if process_counts else 0}`",
        f"- peak rustc count: `{max(rustc_counts) if rustc_counts else 0}`",
        "",
        "## Note",
        "",
        "This is a `top`-style curve, not global machine utilization. Other unrelated host processes are not included.",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    root = Path(args.root)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    prefix = out_dir / f"macos-host-{args.profile_mode}-aarch64-smp{args.smp}-j{args.jobs}-{args.stamp}"
    raw_csv = prefix.with_suffix(".raw-process-tree.csv")
    build_csv = prefix.with_suffix(".per-second.csv")
    summary = prefix.with_suffix(".summary.md")
    svg = prefix.with_suffix(".svg")
    log_path = prefix.with_suffix(".log")

    env = os.environ.copy()
    env.update(
        {
            "ROOT": str(root),
            "JOBS": str(args.jobs),
            "SMP": str(args.smp),
            "STAMP": args.stamp,
            "LOG_DIR": str(out_dir),
            "LOG": str(log_path),
            "SRC_COPY": f"/private/tmp/host-starryos-aligned-j{args.jobs}-src-{args.stamp}",
            "TARGET_DIR": f"/private/tmp/host-starryos-aligned-j{args.jobs}-target-{args.stamp}",
            "PROFILE_MODE": args.profile_mode,
        }
    )

    runner_start = time.time()
    with open(os.devnull, "wb") as devnull:
        proc = subprocess.Popen(
            ["bash", str(args.runner)],
            cwd=str(root),
            env=env,
            stdout=devnull,
            stderr=subprocess.STDOUT,
        )

        rows = []
        try:
            while proc.poll() is None:
                rows.append(sample_process_tree(proc.pid, runner_start, args.smp))
                time.sleep(args.interval)
            rows.append(sample_process_tree(proc.pid, runner_start, args.smp))
        finally:
            rc = proc.wait()

    write_rows(raw_csv, rows, include_build_t=False)
    meta = read_host_build_meta(log_path)
    build_rows = build_window_rows(rows, meta)
    write_rows(build_csv, build_rows, include_build_t=True)
    write_svg(svg, build_rows, f"macOS host StarryOS {args.profile_mode} CPU curve (-j{args.jobs})", args.smp)
    write_summary(summary, build_rows, meta, log_path, raw_csv, build_csv, svg, args.smp, args.profile_mode)

    print(f"runner_rc={rc}")
    print(f"log={log_path}")
    print(f"raw_csv={raw_csv}")
    print(f"build_csv={build_csv}")
    print(f"summary={summary}")
    print(f"svg={svg}")
    if meta.get("build_rc") is not None and meta["build_rc"] != 0:
        return meta["build_rc"]
    return rc


if __name__ == "__main__":
    sys.exit(main())
