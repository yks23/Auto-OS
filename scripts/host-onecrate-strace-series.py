#!/usr/bin/env python3
"""Run `cargo check -p <crate> --target <triple> --offline` under timeout+strace -tt -f; emit time-bucket cumulative counts."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict


def parse_strace_ts_sec(line: str) -> float | None:
    m = re.search(r"\b(\d{2}):(\d{2}):(\d{2})\.(\d+)", line)
    if m:
        h, mn, s, fr = m.groups()
        fr6 = (fr + "000000")[:6]
        return int(h) * 3600 + int(mn) * 60 + int(s) + int(fr6) / 1e6
    m2 = re.match(r"^\s*(\d+\.\d+)", line)
    return float(m2.group(1)) if m2 else None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cwd", default="/work/tgoskits")
    ap.add_argument("--crate", default="ax-errno")
    ap.add_argument("--target", default="riscv64gc-unknown-none-elf")
    ap.add_argument("--bucket-ms", type=int, default=20)
    ap.add_argument("--timeout-sec", type=int, default=600, help="timeout(1) around strace+cargo (host)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    trace = tempfile.NamedTemporaryFile(prefix="strace-1c-", suffix=".log", delete=False)
    trace.close()
    trace_path = trace.name

    inner = [
        "strace",
        "-f",
        "-tt",
        "-o",
        trace_path,
        "--",
        "cargo",
        "check",
        "-p",
        args.crate,
        "--target",
        args.target,
        "--offline",
    ]
    cmd = ["timeout", str(max(args.timeout_sec, 1))] + inner

    env = os.environ.copy()
    env.setdefault("PATH", "/usr/local/cargo/bin:/usr/bin:/bin")

    p = subprocess.run(cmd, cwd=args.cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    rc = p.returncode
    if rc not in (0, 124) and rc is not None:
        print(p.stderr, file=sys.stderr)
        sys.exit(rc)

    raw = open(trace_path, "rb").read().decode("utf-8", errors="replace").splitlines()
    os.unlink(trace_path)

    ts_list: list[float] = []
    for line in raw:
        t = parse_strace_ts_sec(line)
        if t is not None:
            ts_list.append(t)
    if len(ts_list) < 2:
        print("strace log: not enough timestamped lines (timeout or instant fail?)", file=sys.stderr)
        sys.exit(1)

    t0 = ts_list[0]
    t1 = ts_list[-1]
    wall = max(t1 - t0, 1e-9)
    bucket = max(args.bucket_ms, 1) / 1000.0
    counts: defaultdict[int, int] = defaultdict(int)
    for t in ts_list:
        rel = t - t0
        b = int(rel / bucket)
        counts[b] += 1

    max_b = max(counts)
    cumulative: list[int] = []
    running = 0
    times_ms: list[float] = []
    for b in range(max_b + 1):
        running += counts[b]
        cumulative.append(running)
        times_ms.append((b + 1) * args.bucket_ms)

    out = {
        "protocol": f"cargo check -p {args.crate} --target {args.target} --offline",
        "side": "host-linux-strace-tt",
        "cargo_exit": rc,
        "timeout_sec": args.timeout_sec,
        "bucket_ms": args.bucket_ms,
        "wall_ms": wall * 1000.0,
        "strace_lines_with_ts": len(ts_list),
        "times_ms": times_ms,
        "cumulative_syscalls": cumulative,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
    print("wrote", args.out, "wall_ms=", round(out["wall_ms"], 2), "final_cumulative=", cumulative[-1], "cargo_exit=", rc)


if __name__ == "__main__":
    main()
