# HVF SMP8 host CPU utilization

This is host-side QEMU process CPU accounting. On macOS, 800% process CPU is treated as 100% of an 8-vCPU VM.

## Source

- log: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/hvf-aarch64-starryos-smp8-j8-fullcpu-nosrctmp-opt0-cgu256-20260530T191559-fullcpu.log`
- host cpu csv: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/hvf-aarch64-starryos-smp8-j8-fullcpu-nosrctmp-opt0-cgu256-20260530T191559-fullcpu.hostcpu.csv`
- case: `smp8-j8-fullcpu-nosrctmp-opt0-cgu256`
- jobs: `8`
- smp: `8`
- build_start_epoch: `1780139760`
- build_elapsed_s: `551`
- build_rc: `0`
- features: ``

## Data quality

- sampled_intervals_in_build: `543`
- exact_1s_intervals: `535`
- non_1s_intervals: `8`
- expected_build_seconds: `551`

## Utilization

- mean_normalized_8vcpu_pct: `48.92%`
- median_normalized_8vcpu_pct: `54.63%`
- p90_normalized_8vcpu_pct: `72.63%`
- p95_normalized_8vcpu_pct: `77.74%`
- peak_normalized_8vcpu_pct: `93.25%`
- mean_busy_vcpu_equiv: `3.91`
- peak_busy_vcpu_equiv: `7.46`
- seconds_ge_75pct: `39`
- seconds_ge_90pct: `1`
- seconds_ge_95pct: `0`
- seconds_ge_100pct: `0`

Non-1s interval examples: `8s/2s, 80s/2s, 148s/2s, 226s/2s, 309s/2s, 379s/2s, 461s/2s, 543s/2s`
