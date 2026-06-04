#!/usr/bin/env python3
import argparse
import csv
import html
import math
import re
from pathlib import Path


BUILD_START_RE = re.compile(r"===STARRYOS(?:-DEBUG)?-BUILD-START jobs=(\d+) start=(\d+)===")
BUILD_END_RE = re.compile(r"===STARRYOS(?:-DEBUG)?-BUILD-END jobs=(\d+) rc=(\d+) elapsed=(\d+)===")
RUN_BEGIN_RE = re.compile(r"^===HVF-(.*)-RUN-BEGIN===")


def parse_cpu_time(value):
    value = (value or "").strip()
    if not value:
        return None
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        try:
            days = int(day_part)
        except ValueError:
            return None
    parts = value.split(":")
    try:
        if len(parts) == 2:
            minutes = int(parts[0])
            seconds = float(parts[1])
            return days * 86400 + minutes * 60 + seconds
        if len(parts) == 3:
            hours = int(parts[0])
            minutes = int(parts[1])
            seconds = float(parts[2])
            return days * 86400 + hours * 3600 + minutes * 60 + seconds
    except ValueError:
        return None
    return None


def read_log_meta(path):
    meta = {
        "case_name": "",
        "jobs": "",
        "build_start_epoch": None,
        "build_elapsed_s": None,
        "build_end_epoch": None,
        "build_rc": "",
        "features": "",
        "guest_cpu_monitor_interval": "",
        "cpu_count": "",
    }
    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            m = RUN_BEGIN_RE.match(line)
            if m:
                meta["case_name"] = m.group(1)
            m = BUILD_START_RE.search(line)
            if m:
                meta["jobs"] = m.group(1)
                meta["build_start_epoch"] = int(m.group(2))
            m = BUILD_END_RE.search(line)
            if m:
                meta["jobs"] = m.group(1)
                meta["build_rc"] = m.group(2)
                meta["build_elapsed_s"] = int(m.group(3))
            if line.startswith("features="):
                meta["features"] = line.split("=", 1)[1]
            elif line.startswith("guest_cpu_monitor_interval="):
                meta["guest_cpu_monitor_interval"] = line.split("=", 1)[1]
            elif line.startswith("cpu_count="):
                meta["cpu_count"] = line.split("=", 1)[1]
    if meta["build_start_epoch"] is not None and meta["build_elapsed_s"] is not None:
        meta["build_end_epoch"] = meta["build_start_epoch"] + meta["build_elapsed_s"]
    return meta


def read_host_samples(path):
    rows = []
    with path.open("r", encoding="utf-8", errors="ignore", newline="") as f:
        for row in csv.DictReader(f):
            try:
                epoch = int(float(row.get("epoch") or ""))
            except ValueError:
                continue
            cpu_time = parse_cpu_time(row.get("cpu_time", ""))
            try:
                ps_cpu = float(row.get("host_cpu_pct") or "nan")
            except ValueError:
                ps_cpu = math.nan
            try:
                rss_mb = float(row.get("rss_kb") or 0) / 1024.0
            except ValueError:
                rss_mb = math.nan
            try:
                vsz_mb = float(row.get("vsz_kb") or 0) / 1024.0
            except ValueError:
                vsz_mb = math.nan
            rows.append(
                {
                    "epoch": epoch,
                    "pid": row.get("pid", ""),
                    "ps_cpu_pct": ps_cpu,
                    "cpu_time_s": cpu_time,
                    "rss_mb": rss_mb,
                    "vsz_mb": vsz_mb,
                    "elapsed_time": row.get("elapsed_time", ""),
                }
            )
    rows.sort(key=lambda item: item["epoch"])
    return rows


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
        return ordered[int(pos)]
    weight = pos - lo
    return ordered[lo] * (1.0 - weight) + ordered[hi] * weight


def mean(values):
    if not values:
        return math.nan
    return sum(values) / len(values)


def format_float(value, digits=2):
    if value is None or math.isnan(value):
        return ""
    return f"{value:.{digits}f}"


def build_interval_rows(samples, meta, smp, allow_partial=False):
    start_epoch = meta["build_start_epoch"]
    end_epoch = meta["build_end_epoch"]
    if start_epoch is None:
        raise SystemExit("log does not contain STARRYOS-BUILD-START marker")
    if end_epoch is None:
        if not allow_partial or not samples:
            raise SystemExit("log does not contain STARRYOS-BUILD-END marker")
        end_epoch = max(sample["epoch"] for sample in samples)
        meta["build_end_epoch"] = end_epoch
        meta["build_elapsed_s"] = max(0, end_epoch - start_epoch)
        meta["build_rc"] = "partial"

    rows = []
    previous = None
    for sample in samples:
        if previous is None:
            previous = sample
            continue
        wall_delta = sample["epoch"] - previous["epoch"]
        cpu_delta = None
        if sample["cpu_time_s"] is not None and previous["cpu_time_s"] is not None:
            cpu_delta = sample["cpu_time_s"] - previous["cpu_time_s"]
        if wall_delta <= 0 or cpu_delta is None or cpu_delta < 0:
            previous = sample
            continue
        if sample["epoch"] < start_epoch + 1 or sample["epoch"] > end_epoch:
            previous = sample
            continue
        host_cpu_pct = (cpu_delta / wall_delta) * 100.0
        rows.append(
            {
                "second_end": sample["epoch"] - start_epoch,
                "epoch_start": previous["epoch"],
                "epoch_end": sample["epoch"],
                "wall_delta_s": wall_delta,
                "qemu_cpu_delta_s": cpu_delta,
                "host_cpu_pct": host_cpu_pct,
                "host_ps_cpu_pct_end": sample["ps_cpu_pct"],
                "normalized_8vcpu_pct": host_cpu_pct / smp,
                "busy_vcpu_equiv": host_cpu_pct / 100.0,
                "rss_mb_end": sample["rss_mb"],
                "vsz_mb_end": sample["vsz_mb"],
            }
        )
        previous = sample
    return rows


def write_csv(path, rows):
    fields = [
        "second_end",
        "epoch_start",
        "epoch_end",
        "wall_delta_s",
        "qemu_cpu_delta_s",
        "host_cpu_pct",
        "host_ps_cpu_pct_end",
        "normalized_8vcpu_pct",
        "busy_vcpu_equiv",
        "rss_mb_end",
        "vsz_mb_end",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            out = dict(row)
            for key in (
                "qemu_cpu_delta_s",
                "host_cpu_pct",
                "host_ps_cpu_pct_end",
                "normalized_8vcpu_pct",
                "busy_vcpu_equiv",
                "rss_mb_end",
                "vsz_mb_end",
            ):
                out[key] = format_float(out[key], 4 if key == "qemu_cpu_delta_s" else 2)
            writer.writerow(out)


def write_summary(path, rows, meta, smp, source_log, source_csv):
    normalized = [row["normalized_8vcpu_pct"] for row in rows]
    busy = [row["busy_vcpu_equiv"] for row in rows]
    one_second = sum(1 for row in rows if row["wall_delta_s"] == 1)
    gaps = [row for row in rows if row["wall_delta_s"] != 1]
    expected = meta["build_elapsed_s"] or 0
    ge_75 = sum(1 for value in normalized if value >= 75.0)
    ge_90 = sum(1 for value in normalized if value >= 90.0)
    ge_95 = sum(1 for value in normalized if value >= 95.0)
    ge_100 = sum(1 for value in normalized if value >= 100.0)

    lines = [
        "# HVF SMP8 host CPU utilization",
        "",
        "This is host-side QEMU process CPU accounting. On macOS, 800% process CPU is treated as 100% of an 8-vCPU VM.",
        "",
        "## Source",
        "",
        f"- log: `{source_log}`",
        f"- host cpu csv: `{source_csv}`",
        f"- case: `{meta.get('case_name') or ''}`",
        f"- jobs: `{meta.get('jobs') or ''}`",
        f"- smp: `{smp}`",
        f"- build_start_epoch: `{meta.get('build_start_epoch')}`",
        f"- build_elapsed_s: `{meta.get('build_elapsed_s')}`",
        f"- build_rc: `{meta.get('build_rc')}`",
        f"- features: `{meta.get('features') or ''}`",
        "",
        "## Data quality",
        "",
        f"- sampled_intervals_in_build: `{len(rows)}`",
        f"- exact_1s_intervals: `{one_second}`",
        f"- non_1s_intervals: `{len(gaps)}`",
        f"- expected_build_seconds: `{expected}`",
        "",
        "## Utilization",
        "",
        f"- mean_normalized_8vcpu_pct: `{format_float(mean(normalized))}%`",
        f"- median_normalized_8vcpu_pct: `{format_float(percentile(normalized, 50))}%`",
        f"- p90_normalized_8vcpu_pct: `{format_float(percentile(normalized, 90))}%`",
        f"- p95_normalized_8vcpu_pct: `{format_float(percentile(normalized, 95))}%`",
        f"- peak_normalized_8vcpu_pct: `{format_float(max(normalized) if normalized else math.nan)}%`",
        f"- mean_busy_vcpu_equiv: `{format_float(mean(busy))}`",
        f"- peak_busy_vcpu_equiv: `{format_float(max(busy) if busy else math.nan)}`",
        f"- seconds_ge_75pct: `{ge_75}`",
        f"- seconds_ge_90pct: `{ge_90}`",
        f"- seconds_ge_95pct: `{ge_95}`",
        f"- seconds_ge_100pct: `{ge_100}`",
    ]
    if meta.get("build_rc") == "partial":
        lines.extend(
            [
                "",
                "Partial run: the log had a build start marker but no build end marker, so the last host CPU sample was used as the cutoff.",
            ]
        )
    if gaps:
        examples = ", ".join(f"{row['second_end']}s/{row['wall_delta_s']}s" for row in gaps[:8])
        lines.extend(["", f"Non-1s interval examples: `{examples}`"])
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_svg(path, rows, title):
    width = 1200
    height = 420
    pad_left = 64
    pad_right = 24
    pad_top = 42
    pad_bottom = 48
    if not rows:
        path.write_text("<svg xmlns='http://www.w3.org/2000/svg'></svg>\n", encoding="utf-8")
        return
    max_x = max(row["second_end"] for row in rows)
    max_y_data = max(row["normalized_8vcpu_pct"] for row in rows)
    max_y = max(100.0, math.ceil(max_y_data / 10.0) * 10.0)
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom

    def sx(value):
        if max_x <= 0:
            return pad_left
        return pad_left + (value / max_x) * plot_w

    def sy(value):
        return pad_top + (1.0 - min(value, max_y) / max_y) * plot_h

    points = " ".join(f"{sx(row['second_end']):.2f},{sy(row['normalized_8vcpu_pct']):.2f}" for row in rows)
    grid = []
    for pct in range(0, int(max_y) + 1, 20):
        y = sy(pct)
        grid.append(f"<line x1='{pad_left}' y1='{y:.2f}' x2='{width - pad_right}' y2='{y:.2f}' stroke='#e5e7eb'/>")
        grid.append(f"<text x='{pad_left - 10}' y='{y + 4:.2f}' text-anchor='end' font-size='12' fill='#475569'>{pct}%</text>")
    for sec in range(0, int(max_x) + 1, 60):
        x = sx(sec)
        grid.append(f"<line x1='{x:.2f}' y1='{pad_top}' x2='{x:.2f}' y2='{height - pad_bottom}' stroke='#f1f5f9'/>")
        grid.append(f"<text x='{x:.2f}' y='{height - 18}' text-anchor='middle' font-size='12' fill='#475569'>{sec}s</text>")

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <text x="{pad_left}" y="26" font-family="Arial, sans-serif" font-size="18" font-weight="700" fill="#0f172a">{html.escape(title)}</text>
  {''.join(grid)}
  <line x1="{pad_left}" y1="{pad_top}" x2="{pad_left}" y2="{height - pad_bottom}" stroke="#334155"/>
  <line x1="{pad_left}" y1="{height - pad_bottom}" x2="{width - pad_right}" y2="{height - pad_bottom}" stroke="#334155"/>
  <polyline fill="none" stroke="#2563eb" stroke-width="2.5" points="{points}"/>
  <line x1="{pad_left}" y1="{sy(100):.2f}" x2="{width - pad_right}" y2="{sy(100):.2f}" stroke="#dc2626" stroke-width="1.5" stroke-dasharray="6 6"/>
  <text x="{width - pad_right - 4}" y="{sy(100) - 6:.2f}" text-anchor="end" font-family="Arial, sans-serif" font-size="12" fill="#dc2626">8-vCPU full capacity</text>
  <text x="{width / 2:.2f}" y="{height - 4}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">compile time</text>
  <text transform="translate(16 {height / 2:.2f}) rotate(-90)" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">normalized CPU utilization</text>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def write_top_cpu_svg(path, rows, title, smp):
    width = 1200
    height = 420
    pad_left = 70
    pad_right = 24
    pad_top = 42
    pad_bottom = 48
    if not rows:
        path.write_text("<svg xmlns='http://www.w3.org/2000/svg'></svg>\n", encoding="utf-8")
        return
    max_x = max(row["second_end"] for row in rows)
    max_y_data = max(row["host_cpu_pct"] for row in rows)
    full_capacity = smp * 100.0
    max_y = max(full_capacity, math.ceil(max_y_data / 100.0) * 100.0)
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom

    def sx(value):
        return pad_left if max_x <= 0 else pad_left + (value / max_x) * plot_w

    def sy(value):
        return pad_top + (1.0 - min(value, max_y) / max_y) * plot_h

    points = " ".join(f"{sx(row['second_end']):.2f},{sy(row['host_cpu_pct']):.2f}" for row in rows)
    grid = []
    step = 100
    for pct in range(0, int(max_y) + 1, step):
        y = sy(pct)
        grid.append(f"<line x1='{pad_left}' y1='{y:.2f}' x2='{width - pad_right}' y2='{y:.2f}' stroke='#e5e7eb'/>")
        grid.append(f"<text x='{pad_left - 10}' y='{y + 4:.2f}' text-anchor='end' font-size='12' fill='#475569'>{pct}%</text>")
    for sec in range(0, int(max_x) + 1, 30):
        x = sx(sec)
        grid.append(f"<line x1='{x:.2f}' y1='{pad_top}' x2='{x:.2f}' y2='{height - pad_bottom}' stroke='#f1f5f9'/>")
        grid.append(f"<text x='{x:.2f}' y='{height - 18}' text-anchor='middle' font-size='12' fill='#475569'>{sec}s</text>")

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <text x="{pad_left}" y="26" font-family="Arial, sans-serif" font-size="18" font-weight="700" fill="#0f172a">{html.escape(title)}</text>
  {''.join(grid)}
  <line x1="{pad_left}" y1="{pad_top}" x2="{pad_left}" y2="{height - pad_bottom}" stroke="#334155"/>
  <line x1="{pad_left}" y1="{height - pad_bottom}" x2="{width - pad_right}" y2="{height - pad_bottom}" stroke="#334155"/>
  <polyline fill="none" stroke="#0f766e" stroke-width="2.5" points="{points}"/>
  <line x1="{pad_left}" y1="{sy(full_capacity):.2f}" x2="{width - pad_right}" y2="{sy(full_capacity):.2f}" stroke="#dc2626" stroke-width="1.5" stroke-dasharray="6 6"/>
  <text x="{width - pad_right - 4}" y="{sy(full_capacity) - 6:.2f}" text-anchor="end" font-family="Arial, sans-serif" font-size="12" fill="#dc2626">{int(full_capacity)}% = {smp} vCPU full</text>
  <text x="{width / 2:.2f}" y="{height - 4}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">compile time</text>
  <text transform="translate(18 {height / 2:.2f}) rotate(-90)" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#475569">QEMU process CPU in top</text>
</svg>
"""
    path.write_text(svg, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Extract second-level host CPU utilization for HVF StarryOS builds.")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--host-cpu-csv", required=True, type=Path)
    parser.add_argument("--smp", type=int, default=8)
    parser.add_argument("--out-prefix", required=True, type=Path)
    parser.add_argument("--allow-partial", action="store_true")
    args = parser.parse_args()

    meta = read_log_meta(args.log)
    samples = read_host_samples(args.host_cpu_csv)
    rows = build_interval_rows(samples, meta, args.smp, allow_partial=args.allow_partial)

    args.out_prefix.parent.mkdir(parents=True, exist_ok=True)
    out_csv = args.out_prefix.with_suffix(".per-second.csv")
    out_summary = args.out_prefix.with_suffix(".summary.md")
    out_svg = args.out_prefix.with_suffix(".svg")
    out_top_svg = args.out_prefix.with_suffix(".topcpu.svg")

    write_csv(out_csv, rows)
    write_summary(out_summary, rows, meta, args.smp, args.log, args.host_cpu_csv)
    write_svg(out_svg, rows, f"StarryOS self-build SMP{args.smp}: host CPU utilization")
    write_top_cpu_svg(out_top_svg, rows, f"StarryOS self-build SMP{args.smp}: QEMU process CPU", args.smp)

    normalized = [row["normalized_8vcpu_pct"] for row in rows]
    print(f"csv={out_csv}")
    print(f"summary={out_summary}")
    print(f"svg={out_svg}")
    print(f"top_cpu_svg={out_top_svg}")
    print(
        "mean_normalized_pct="
        f"{format_float(mean(normalized))} peak_normalized_pct={format_float(max(normalized) if normalized else math.nan)} samples={len(rows)}"
    )


if __name__ == "__main__":
    main()
