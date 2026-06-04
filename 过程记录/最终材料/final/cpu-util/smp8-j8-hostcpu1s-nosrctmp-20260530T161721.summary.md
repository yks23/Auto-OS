# HVF SMP8 host CPU utilization

This is host-side QEMU process CPU accounting. On macOS, 800% process CPU is treated as 100% of an 8-vCPU VM.

## Source

- log: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/hvf-aarch64-starryos-smp8-j8-hostcpu1s-nosrctmp-opt0-cgu256-20260530T161721.log`
- host cpu csv: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/hvf-aarch64-starryos-smp8-j8-hostcpu1s-nosrctmp-opt0-cgu256-20260530T161721.hostcpu.csv`
- case: `smp8-j8-hostcpu1s-nosrctmp-opt0-cgu256`
- jobs: `8`
- smp: `8`
- build_start_epoch: `1780129043`
- build_elapsed_s: `24`
- build_rc: `partial`
- features: ``

## Data quality

- sampled_intervals_in_build: `24`
- exact_1s_intervals: `24`
- non_1s_intervals: `0`
- expected_build_seconds: `24`

## Utilization

- mean_normalized_8vcpu_pct: `20.54%`
- median_normalized_8vcpu_pct: `20.87%`
- p90_normalized_8vcpu_pct: `21.25%`
- p95_normalized_8vcpu_pct: `21.46%`
- peak_normalized_8vcpu_pct: `21.75%`
- mean_busy_vcpu_equiv: `1.64`
- peak_busy_vcpu_equiv: `1.74`
- seconds_ge_75pct: `0`
- seconds_ge_90pct: `0`
- seconds_ge_95pct: `0`
- seconds_ge_100pct: `0`

Partial run: the log had a build start marker but no build end marker, so the last host CPU sample was used as the cutoff.
