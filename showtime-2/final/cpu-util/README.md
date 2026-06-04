# SMP8 CPU utilization sampling

## What is measured

The reliable metric is host-side QEMU process CPU time:

- `host_cpu_pct`: QEMU process CPU time delta divided by wall-clock delta. On macOS this can exceed 100%.
- `normalized_8vcpu_pct`: `host_cpu_pct / 8`. For an `-smp 8` VM, macOS `800%` process CPU is treated as `100%` of the 8-vCPU capacity.
- `busy_vcpu_equiv`: `host_cpu_pct / 100`, i.e. approximate busy virtual cores.

This avoids using the old guest `/proc/stat` data, because the historical diagnostic log shows non-monotonic aggregate CPU counters. That was already turned into the `/proc/stat` monotonicity PR candidate; those old 10-second samples cannot honestly be converted into exact per-second CPU utilization.

## Scripts

Run a macOS host aligned build and collect the corresponding process-tree CPU curve:

```sh
cd /Users/txc/code/Auto-OS
python3 /Users/txc/code/Auto-OS/showtime-2/scripts/run-host-build-cpu-curve.py \
  --jobs 8 \
  --smp 8 \
  --profile-mode guest-aligned \
  --interval 1
```

Run the native macOS release profile, without the guest-aligned `CARGO_PROFILE_RELEASE_*` overrides:

```sh
cd /Users/txc/code/Auto-OS
python3 /Users/txc/code/Auto-OS/showtime-2/scripts/run-host-build-cpu-curve.py \
  --jobs 8 \
  --smp 8 \
  --profile-mode native-release \
  --interval 1
```

Run a full second-level SMP8 build sample from a normal macOS terminal:

```sh
cd /Users/txc/code/Auto-OS
bash /Users/txc/code/Auto-OS/showtime-2/scripts/run-hvf-starryos-smp8-hostcpu-second.sh
```

Useful override when the guest-side tmpfs source copy is too slow:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=0 bash /Users/txc/code/Auto-OS/showtime-2/scripts/run-hvf-starryos-smp8-hostcpu-second.sh
```

Literal two-terminal `top` mode can also be launched automatically:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=1 bash /Users/txc/code/Auto-OS/showtime-2/scripts/start-smp8-top-two-terminal.sh
```

It opens one macOS Terminal tab for the SMP8 build and one macOS Terminal tab for `top -pid` sampling.

Manual two-terminal `top` mode:

Terminal A runs the guest build:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=0 bash /Users/txc/code/Auto-OS/showtime-2/scripts/run-hvf-starryos-smp8-hostcpu-second.sh
```

Terminal B samples the newest QEMU process with macOS `top`:

```sh
cd /Users/txc/code/Auto-OS
pid="$(pgrep -n -f 'qemu-system-aarch64.*starryos-hvf-smp8-hvfopt-wake-local')"
bash /Users/txc/code/Auto-OS/showtime-2/scripts/monitor-qemu-top-cpu.sh \
  "$pid" \
  /Users/txc/code/Auto-OS/showtime-2/final/cpu-util/qemu-top-$(date +%Y%m%dT%H%M%S).csv \
  1
```

After Terminal A finishes, parse the build log plus Terminal B's top CSV:

```sh
python3 /Users/txc/code/Auto-OS/showtime-2/scripts/extract-hvf-host-cpu-util.py \
  --log /path/to/hvf-aarch64-starryos-xxx.log \
  --host-cpu-csv /path/to/qemu-top-xxx.csv \
  --smp 8 \
  --out-prefix /Users/txc/code/Auto-OS/showtime-2/final/cpu-util/qemu-top-xxx
```

The runner writes:

- raw QEMU/guest log: `hvf-aarch64-starryos-*.log`
- host CPU raw samples: `hvf-aarch64-starryos-*.hostcpu.csv`
- parsed per-second CSV: `smp8-j8-hostcpu1s-*.per-second.csv`
- summary: `smp8-j8-hostcpu1s-*.summary.md`
- SVG chart: `smp8-j8-hostcpu1s-*.svg`

To parse an existing run manually:

```sh
python3 /Users/txc/code/Auto-OS/showtime-2/scripts/extract-hvf-host-cpu-util.py \
  --log /path/to/run.log \
  --host-cpu-csv /path/to/run.hostcpu.csv \
  --smp 8 \
  --out-prefix /path/to/out-prefix
```

For a deliberately interrupted diagnostic run:

```sh
python3 /Users/txc/code/Auto-OS/showtime-2/scripts/extract-hvf-host-cpu-util.py \
  --allow-partial \
  --log /path/to/run.log \
  --host-cpu-csv /path/to/run.hostcpu.csv \
  --smp 8 \
  --out-prefix /path/to/out-prefix
```

## Current complete evidence

The full SMP8/jobs=8 StarryOS guest self-build sample completed successfully on 2026-05-30:

- parsed CSV: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.per-second.csv`
- summary: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.summary.md`
- normalized SVG: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.svg`
- top-style SVG: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.topcpu.svg`
- presentation chart: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-fullcpu-occupancy-time.svg`

Complete result:

- build result: `rc=0`
- build window: `551s`
- sampled intervals in build: `543`
- exact 1-second intervals: `535`
- mean normalized 8-vCPU utilization: `48.92%`
- median normalized 8-vCPU utilization: `54.63%`
- peak normalized 8-vCPU utilization: `93.25%`
- peak QEMU process CPU: `746%`
- mean busy vCPU equivalent: `3.91`
- peak busy vCPU equivalent: `7.46`
- seconds at or above 75% of 8-vCPU capacity: `39`
- seconds at or above 90% of 8-vCPU capacity: `1`

## Historical partial evidence

Inside the Codex desktop execution environment, long HVF/QEMU processes were repeatedly terminated by an external SIGTERM before a full build could complete. This happened even when the build and `top -pid` monitor were launched through macOS Terminal from this session. The direct-compile validation did enter the build window and produced exact 1-second samples for the first 24 seconds:

- parsed CSV: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-nosrctmp-20260530T161721.per-second.csv`
- summary: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-nosrctmp-20260530T161721.summary.md`
- SVG: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-nosrctmp-20260530T161721.svg`

Partial result:

- exact 1-second intervals: `24`
- mean normalized 8-vCPU utilization: `20.54%`
- peak normalized 8-vCPU utilization: `21.75%`
- mean busy vCPU equivalent: `1.64`
- seconds at or above 90% of 8-vCPU capacity: `0`

This partial result was evidence that the sampling and parser were correct. It has now been superseded by the complete `551s` run above.
