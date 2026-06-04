# perf(starry): gate display device support

## Problem

StarryOS self-build does not use framebuffer or DRM device support, but `starry-kernel` currently depends on `ax-display` unconditionally and always compiles the `/dev/fb0` and `/dev/dri/card0` device code.

This keeps display-related crates and device code in the self-build cargo graph even for serial-only, headless QEMU/HVF runs.

## Root Cause

Display runtime support is already modeled as a feature in `ax-feat` / `ax-runtime`, but `starry-kernel` still has a hard dependency on `ax-display`. The pseudo device layer also unconditionally compiles the framebuffer and DRM card device modules.

## Fix Summary

- Add a `starry-kernel/display` feature.
- Make `ax-display` an optional dependency activated by that feature.
- Keep normal `starryos/qemu` behavior by enabling `starry-kernel/display` from the existing qemu feature.
- Compile `/dev/fb0`, `/dev/dri/card0`, and `/dev/dri/renderD128` only when `display` is enabled.

## Why These Areas

- `os/StarryOS/kernel/Cargo.toml`: owns the kernel dependency graph.
- `os/StarryOS/starryos/Cargo.toml`: preserves normal qemu behavior by enabling the new kernel display feature.
- `os/StarryOS/kernel/src/pseudofs/dev/mod.rs`: owns the user-visible framebuffer/DRM device nodes that reference `ax_display`.

## Current Local Evidence

- Worktree: `/private/tmp/tgoskits-display-gating-pr`
- Branch: `perf/starry-display-feature-gating`
- Base: `upstream/dev@73e21e907`
- Files changed:
  - `os/StarryOS/kernel/Cargo.toml`
  - `os/StarryOS/starryos/Cargo.toml`
  - `os/StarryOS/kernel/src/pseudofs/dev/mod.rs`
- `cargo fmt --check`: PASS
- `git diff --check`: PASS
- `cargo metadata --offline --no-deps --format-version=1`: confirms `ax-display.optional = true` and `starryos/qemu` enables `starry-kernel/display`.
- Full guest self-build injection experiment: old runner PASS `340s`, but the injection did not run because guest rootfs lacks `python3`; it still compiled `ax-driver-display` plus `ax-display`.
- Log: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-displaygating-rustcthreads2-opt0-cgu256-20260525T230204.log`
- Failure clue: `/opt/hvf-auto.sh: line 52: python3: not found`
- Marker: `===STARRYOS-BUILD-PASS jobs=8 elapsed=340===`
- Fixed-runner preflight:
  - `sh -n showtime-2/scripts/run-hvf-starryos-guest-build.sh`: PASS
  - `git diff --check`: PASS
  - temp worktree feature-off `cargo tree -i ax-display`: package not in graph after patch
  - temp worktree feature-off `cargo tree -i ax-driver-display`: package not in graph after patch
  - temp worktree feature-off `cargo check -p starry-kernel --target aarch64-unknown-none-softfloat --no-default-features --features 'dev-log,ext4,ax-feat/ipi'`: PASS in `28.54s`
- Fixed-runner full guest self-build:
  - display-only gating: PASS `348s`, no `ax-display` / `ax-driver-display` compile entries.
  - display+DRM gating: PASS `338s`, no `ax-display` / `ax-driver-display` compile entries; `starry-kernel` warnings drop from 94 to 1.
  - upstream/dev worktree feature-off check: `cargo check -p starry-kernel --target aarch64-unknown-none-softfloat --no-default-features --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'`: PASS in `4.25s` after Cargo index refresh.
  - Logs:
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-displaygating-sed-rustcthreads2-opt0-cgu256-20260525T233530.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-displaydrmgating-rustcthreads2-opt0-cgu256-20260525T234646.log`

## Not Ready Yet

Full `cargo check` is currently blocked before compilation by Cargo index freshness:

```text
error: failed to select a version for the requirement `log = "^0.4"` (locked to 0.4.30)
candidate versions found which didn't match: 0.4.29
```

Online refresh also fails with `Could not resolve host: index.crates.io`.

The old guest self-build result is not a valid performance measurement for this patch because the Python-based injection failed and the script kept running. The runner has been changed to use shell/sed injection and fail fast on injection errors. Before treating it as a performance PR, rerun a seconds-level feature graph check:

```sh
cd /private/tmp/tgoskits-display-gating-pr
cargo tree -i ax-display --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/bus-pci,gic-v3,cntv-timer,smp'
cargo tree -i ax-driver-display --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/bus-pci,gic-v3,cntv-timer,smp'
```

Before pushing this as a PR, rerun:

```sh
cd /private/tmp/tgoskits-display-gating-pr
git diff --check
cargo fmt --check
CARGO_NET_OFFLINE=false cargo check -p starry-kernel \
  --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'dev-log,ext4,ax-feat/ipi'
CARGO_NET_OFFLINE=false cargo check -p starry-kernel \
  --target aarch64-unknown-none-softfloat \
  --features 'display'
```

This is now a structure cleanup PR candidate, not a speedup PR: the best fixed-runner display+DRM gating run is `338s`, slower than the current best `331s`.

## Remaining Risk

This is intended as a feature-graph cleanup, not an ABI change for normal qemu builds. The main risk is accidentally hiding `/dev/dri` or `/dev/fb0` from qemu configurations that expect display support, so `starryos/qemu` must keep enabling the new `starry-kernel/display` feature.

IP networking should not be grouped into this PR. `ax-net-ng` is also expensive, but AF_UNIX, netlink, socket syscalls, and `/dev/log` are intertwined enough that it needs a separate design and test suite.
