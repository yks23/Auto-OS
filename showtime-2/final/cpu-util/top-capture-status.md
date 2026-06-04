# QEMU top capture status

## Current status

A full QEMU process CPU-time capture has now completed from this session with `SOURCE_TMPFS=0`, `SMP=8`, and `cargo jobs=8`.

Complete result:

- build result: `rc=0`
- build window: `551s`
- sampled intervals in build: `543`
- mean normalized 8-vCPU utilization: `48.92%`
- peak normalized 8-vCPU utilization: `93.25%`
- top-style QEMU CPU graph:
  `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.topcpu.svg`
- presentation occupancy-time graph:
  `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-fullcpu-occupancy-time.svg`

The two-terminal method is still implemented and was tested from this Codex desktop session:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=1 bash /Users/txc/code/Auto-OS/showtime-2/scripts/start-smp8-top-two-terminal.sh
```

It successfully opened one macOS Terminal tab for the SMP8 build and another tab for `top -pid` sampling. The QEMU process was detected and sampled.

Earlier, in this Codex desktop environment, long-running HVF/QEMU processes were terminated externally by `SIGTERM`. The two-terminal attempt produced:

```text
qemu-system-aarch64: terminating on signal 15 from pid 57481
```

That happened before the guest completed the source-copy phase, so that earlier attempt could not provide a full compile-window top curve. The later direct `SOURCE_TMPFS=0` run above supersedes it for the final PPT evidence.

## What is already available

- A complete 457s Cargo timing curve from a previous successful run:
  `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-cargo-jsoncpu-20260524T233333.timeline.svg`

- A partial QEMU/top-style compile-window sample:
  `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-nosrctmp-20260530T161721.topcpu.svg`

- A complete QEMU/top-style compile-window sample:
  `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.topcpu.svg`

- The full two-terminal top capture scripts:
  `/Users/txc/code/Auto-OS/showtime-2/scripts/start-smp8-top-two-terminal.sh`
  `/Users/txc/code/Auto-OS/showtime-2/scripts/monitor-qemu-top-cpu.sh`

## How to get the full top curve

Run this from a normal macOS Terminal session where QEMU is not managed by the Codex desktop process watchdog:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=1 bash /Users/txc/code/Auto-OS/showtime-2/scripts/start-smp8-top-two-terminal.sh
```

If source-copy time is not part of the measurement target and direct rootfs source access is acceptable:

```sh
cd /Users/txc/code/Auto-OS
SOURCE_TMPFS=0 bash /Users/txc/code/Auto-OS/showtime-2/scripts/start-smp8-top-two-terminal.sh
```

The parser will generate:

- `*.per-second.csv`
- `*.summary.md`
- `*.svg`
- `*.topcpu.svg`
