# macOS host aligned StarryOS build CPU curve

This is a host-side process-tree `%CPU` sample for the same aligned StarryOS build profile.
It includes the build runner's descendant processes, mainly `cargo`, `rustc`, and build scripts.

## Source

- log: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-aligned-aarch64-smp8-j8-20260530T164300-host-j8.log`
- raw process-tree csv: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-aligned-aarch64-smp8-j8-20260530T164300-host-j8.raw-process-tree.csv`
- build-window csv: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-aligned-aarch64-smp8-j8-20260530T164300-host-j8.per-second.csv`
- svg: `/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-aligned-aarch64-smp8-j8-20260530T164300-host-j8.svg`
- jobs: `8`
- smp config: `8`
- build_elapsed_s: `89`
- build_rc: `0`

## CPU utilization

- sampled build-window points: `75`
- mean process-tree CPU: `130.5%`
- median process-tree CPU: `107.2%`
- p95 process-tree CPU: `238.6%`
- peak process-tree CPU: `259.0%`
- mean busy-core equivalent: `1.30`
- peak busy-core equivalent: `2.59`
- mean normalized 8-core utilization: `16.3%`
- peak normalized 8-core utilization: `32.4%`
- seconds >= 400% CPU: `0`
- seconds >= 600% CPU: `0`
- seconds >= 700% CPU: `0`
- peak process count: `16`
- peak rustc count: `8`

## Note

This is a `top`-style curve, not global machine utilization. Other unrelated host processes are not included.
