# perf(starry): gate dynamic debug dependency

## Problem

StarryOS self-build 的快速反馈 profile 会关闭 `starry-kernel` 默认的 `dynamic_debug`，并显式保留 `ax-feat/ipi` 作为 SMP correctness feature。关闭该 feature 后，`ddebug` 仍作为普通依赖进入 build graph，`/proc/dynamic_debug` 控制路径和 `#[ddebug::named]` 也仍然被无条件编译。

这让“关闭 dynamic debug 以缩短 self-build 图”的配置没有真正剪掉 dynamic-debug 子系统。

## Root Cause

`starry-kernel` 的 `dynamic_debug` feature 只声明了 `ax-feat/ipi`，但 `ddebug = "0.5"` 是无条件 dependency。代码侧也无条件编译 dynamic-debug procfs 控制文件和 `ddebug::named` attribute。

因此只要编译 `starry-kernel`，Cargo 仍会解析并编译 `ddebug` 相关 crate，即使用户已经关闭 `dynamic_debug`。

## Fix Summary

- Make `ddebug` an optional dependency.
- Gate `dep:ddebug` behind `dynamic_debug`.
- Compile `/proc/dynamic_debug` and its pseudofs helper only when `dynamic_debug` is enabled.
- Use `cfg_attr(feature = "dynamic_debug", ddebug::named)` for `sys_chdir`.
- Keep `static-keys` unconditional because `ktracepoint` still depends on it.

## Why These Areas

- `os/StarryOS/kernel/Cargo.toml`: owns the feature graph and dependency activation.
- `dyn_debug.rs`: owns the dynamic-debug macros and initialization API.
- `pseudofs/mod.rs` and `pseudofs/proc.rs`: own the `/proc/dynamic_debug` user-visible control path.
- `syscall/fs/ctl.rs`: contains a dynamic-debug named callsite that must compile when the feature is disabled.

## Test Evidence

- Branch: `/private/tmp/tgoskits-optional-ddebug-upstream-pr`
- Commit: `d415b1700 perf(starry): gate dynamic debug dependency`
- Base: `upstream/dev@73e21e907`
- `git diff --check`: PASS
- `cargo fmt --check`: PASS
- `cargo metadata --offline --no-deps --format-version=1`: confirms `ddebug.optional = true` and `dynamic_debug = ["ax-feat/ipi", "dep:ddebug"]`
- Guest self-build evidence with the fast no-dynamic-debug profile:
  - `jobs=8`: `===STARRYOS-BUILD-PASS jobs=8 elapsed=341===`
  - `jobs=1`: `===STARRYOS-BUILD-PASS jobs=1 elapsed=422===`
  - `jobs=8 + rustc -Z threads=2`: `===STARRYOS-BUILD-PASS jobs=8 elapsed=331===`
  - `jobs=8 + rustc -Z threads=3`: `===STARRYOS-BUILD-PASS jobs=8 elapsed=338===`
  - `jobs=8 + rustc -Z threads=4`: `===STARRYOS-BUILD-PASS jobs=8 elapsed=349===`
  - `jobs=8 + rustc -Z threads=2 + codegen-units=192`: `===STARRYOS-BUILD-PASS jobs=8 elapsed=358===`，慢于 `cgu256`，所以 `cgu256 + threads2` 仍是当前甜点。
  - Logs:
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-stage-opt0-cgu256-20260525T200940.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j1-wakelocal-optionalddebug-stage-opt0-cgu256-20260525T201745.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-rustcthreads2-opt0-cgu256-20260525T212418.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-rustcthreads3-opt0-cgu256-20260525T215258.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-rustcthreads4-opt0-cgu256-20260525T214525.log`
    - `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-optionalddebug-rustcthreads2-opt0-cgu192-20260525T223044.log`

## Not Ready Yet

`cargo tree` / `cargo check` on the fresh upstream-dev worktree is currently blocked by local Cargo registry freshness/network:

- `Cargo.lock` wants `log 0.4.30`.
- Local offline index only has `log 0.4.29`.
- Online Cargo index update repeatedly fails with `Could not resolve host: index.crates.io` or transfer stalls. Rechecked on 2026-05-25 22:30 CST; the cargo process still could not refresh the index and was terminated after repeated retry warnings so it would not block the self-build experiment.

Before pushing the PR, rerun:

```sh
cd /private/tmp/tgoskits-optional-ddebug-upstream-pr
git diff --check
cargo fmt --check
cargo metadata --no-deps --format-version=1
cargo tree -p starry-kernel --no-default-features --target aarch64-unknown-none-softfloat -i ddebug
AX_CONFIG_PATH=test-suit/starryos/normal/qemu-smp4/build-aarch64-unknown-none-softfloat.toml \
  cargo check -p starryos --target aarch64-unknown-none-softfloat \
  --no-default-features --features 'qemu,smp,gic-v3,cntv-timer,ax-feat/ipi'
```

The expected `cargo tree -i ddebug` result for `--no-default-features` is no dependency path; with `dynamic_debug` enabled, `ddebug` should appear through `starry-kernel`.

## Remaining Risk

This is a feature-graph cleanup, not a user ABI change. The main risk is accidentally breaking the default dynamic-debug-enabled path, so the PR should not be marked ready until both feature-off and feature-on cargo checks pass.
