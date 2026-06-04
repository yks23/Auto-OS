# macOS host StarryOS build CPU curve

This is a host-side process-tree `%CPU` sample for the `native-release` StarryOS build profile.
It includes the build runner's descendant processes, mainly `cargo`, `rustc`, and build scripts.

## Source

- log: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/macos-host-native-release-aarch64-smp8-j8-20260530T170100-native-j8.log`
- raw process-tree csv: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/macos-host-native-release-aarch64-smp8-j8-20260530T170100-native-j8.raw-process-tree.csv`
- build-window csv: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/macos-host-native-release-aarch64-smp8-j8-20260530T170100-native-j8.per-second.csv`
- svg: `/Users/txc/code/Auto-OS/showtime-2/final/cpu-util/macos-host-native-release-aarch64-smp8-j8-20260530T170100-native-j8.svg`
- jobs: `8`
- smp config: `8`
- profile_mode: `native-release`
- build_elapsed_s: `42`
- build_rc: `0`

## CPU utilization

- sampled build-window points: `41`
- mean process-tree CPU: `112.7%`
- median process-tree CPU: `98.9%`
- p95 process-tree CPU: `201.2%`
- peak process-tree CPU: `299.8%`
- mean busy-core equivalent: `1.13`
- peak busy-core equivalent: `3.00`
- mean normalized 8-core utilization: `14.1%`
- peak normalized 8-core utilization: `37.5%`
- seconds >= 400% CPU: `0`
- seconds >= 600% CPU: `0`
- seconds >= 700% CPU: `0`
- peak process count: `15`
- peak rustc count: `8`

## Note

This is a `top`-style curve, not global machine utilization. Other unrelated host processes are not included.
