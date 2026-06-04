# fix(starry): keep /proc/stat CPU counters monotonic

## Summary

- 修复 `/proc/stat` aggregate `cpu` user/system 计数在短命 CPU-bound 进程退出后可能倒退的问题。
- 将 StarryOS 任务 CPU time 在 timer tick / syscall boundary `poll()` 时同步累加到 boot-wide 计数器。
- `/proc/stat` 使用 boot-wide CPU jiffies 输出 aggregate CPU time，不再从当前仍存活的 task table 重算。
- 新增 StarryOS SMP 回归测例：子进程消耗 CPU 后退出，父进程确认 `/proc/stat` 第一行 `cpu` 计数不低于运行期间峰值。

## Root Cause

在 8 核 StarryOS guest self-build 的 CPU monitor 日志中，`/proc/stat` 出现两个观测问题：

- `cpu0..cpu7` 当前仍是平均分摊的近似值，不能作为真实 per-CPU 利用率；
- 更严重的是 aggregate `cpu` 的 user/system 总量会倒退。

根因是 `render_stat()` 只遍历当前 task table，把仍然存活的任务 CPU time 相加。Rust/Cargo workload 会创建大量短命 `rustc`、build script、helper 进程；这些进程退出并被回收后，它们的 CPU time 不再出现在当前 task table 中，于是 `/proc/stat` aggregate 计数可能下降。Linux `/proc/stat` 的 CPU 计数语义应是自启动以来累计的单调计数，监控工具也依赖这一点计算 CPU busy delta。

## Fix

让 `TimeManager::tick()` 和 `TimeManager::poll()` 返回本次新记账的 user/system delta。StarryOS task 层在三个 CPU time 记账入口累加这些 delta：

- timer IRQ 路径 `tick_cpu_time()`
- timer poll 路径 `poll_timer()`
- user/kernel state 切换路径 `set_timer_state()`

`/proc/stat` 继续用 task table 计算 `procs_running` / `procs_blocked`，但 aggregate `cpu` user/system 改为读取 boot-wide jiffies。这样短命任务退出不会让 `/proc/stat` 的累计 CPU 计数回落。

当前 per-CPU 行仍按 aggregate 平均分摊；本 PR 只修复 aggregate 单调性，不声称提供精确 per-CPU accounting。

## Test Plan

Clean PR candidate branch:

```sh
/private/tmp/tgoskits-procstat-pr
branch: fix/proc-stat-monotonic-cpu-time
base: upstream/dev e9c421670
commit: 2009098ce
pushed: origin/fix/proc-stat-monotonic-cpu-time
```

Local validation:

```sh
git diff --check
cargo fmt --check
CARGO_NET_OFFLINE=true cargo check -p starry-kernel \
  --target aarch64-unknown-none-softfloat \
  --no-default-features \
  --features 'dev-log,ext4,ax-feat/defplat,ax-feat/irq,ax-feat/ipi,ax-feat/rtc,ax-feat/smp'
cc -std=c11 -Wall -Wextra -Werror \
  test-suit/starryos/normal/qemu-smp1/bugfix/bug-proc-stat-monotonic/c/src/main.c \
  -o /tmp/bug-proc-stat-monotonic-host
```

Validation notes:

- `starry-kernel` AArch64 check PASS; after cache, repeat check PASS in `0.39s`.
- C regression source compiles cleanly on host with `-Wall -Wextra -Werror`.
- `cargo test -p starry-kernel ...` is not a valid local gate on macOS for this crate: it tries to build target AArch64 inline assembly with the host assembler and fails in baseline trap asm.
- `cargo xtask starry test qemu --help` / QEMU test discovery is currently blocked by crates.io DNS / `static.crates.io` transfer failures; push/CI or a warmed local dependency cache should run the new QEMU case.
- Draft PR creation from this machine was blocked by GitHub API DNS/connectivity (`api.github.com` resolving timeout), but the branch is pushed and ready for a base `dev` PR.

## Test-suite

新增：

```text
test-suit/starryos/normal/qemu-smp1/bugfix/bug-proc-stat-monotonic/
```

测例逻辑：

- 父进程读取 `/proc/stat` 第一行 `cpu` 的 `user + nice + system`。
- fork 一个 CPU-bound 子进程。
- 子进程运行期间父进程持续读取 `/proc/stat` 并记录峰值。
- 子进程退出并 `waitpid()` 后，父进程再次读取 `/proc/stat`。
- 如果退出后的计数低于运行期间峰值，则 FAIL。

它挂入 `qemu-smp1/bugfix/qemu-riscv64.toml`。测例本身不依赖 SMP；单核下短命 CPU-bound 子进程退出同样能覆盖 aggregate CPU 计数倒退问题。这样也避免触发当前 CI 中缺失的 loongarch64 SMP4 rootfs release。

预期 PASS marker：

```text
PASS: /proc/stat cpu total is monotonic across child exit
```

## Remaining Risk

- 这个 PR 修复的是 aggregate `/proc/stat` 单调性和监控可信度，不是 8 核 self-build 4x 加速本身。
- per-CPU 行仍然是平均分摊近似值。后续如果要精确分析 runqueue/CPU utilization，需要继续做 per-CPU accounting 或新增专用 scheduler counters。
