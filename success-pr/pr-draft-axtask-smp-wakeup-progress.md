# fix(axtask): preserve SMP wakeup progress across run queues

## Summary

- 修复 SMP 下阻塞任务/异步任务被唤醒后放入远端 runqueue 但缺少有效推进的问题。
- 为 wait/future wakeup 使用更贴近 locality 的 runqueue 选择：优先当前 CPU，其次任务上次运行 CPU，最后才走普通选择器。
- 在任务被加入远端 runqueue 时发送 IPI/reschedule kick，避免依赖无关 timer、proc monitor 或用户态 tickle 才能继续前进。
- 保留已有调度策略，只把 wakeup 路径和 new task round-robin 路径区分开。

## Root Cause

StarryOS guest 内 `cargo build -j8` 的长尾最初表现为 cargo 父进程 sleeping、没有 rustc/build-script 子进程。我们先排除了基础语义：

- direct rustc 24/64 crate PASS
- Cargo mini 48/64 crate PASS
- eventfd/poll/epoll + pipe worker PASS
- Cargo worker accounting/reaper/condvar PASS
- `flock(LOCK_EX)` 和 `fcntl(F_SETLKW)` PASS

随后 Cargo fingerprint wave 给出更小的信号：旧 wakeup 路径下，`jobs=8` 无 monitor/tickle 会在冷构建尾部失去进展；加入一个很轻的周期性 `sleep; /bin/true` tickle 就能 PASS。说明问题不是 Cargo 特判，也不是基础 wait/pipe/file-lock 语义，而是 SMP wakeup/runqueue 前进性。

旧路径复用了 new-task round-robin 的 runqueue 选择逻辑。阻塞任务被唤醒时可能被放到远端 runqueue，但没有对应 IPI/reschedule 推动远端 CPU 及时调度；future wakeup 也可能以 `resched=false` 进入队列，导致进展依赖外部中断或周期性用户态活动。

## Fix

新增 wakeup 专用 runqueue selector：

- 当前 CPU 满足 affinity 时优先本地入队，减少跨 CPU 唤醒成本。
- 当前 CPU 不合适时优先任务 last CPU，保持缓存/locality。
- 只有前两者都不合适时才退回普通 runqueue selector。

在 `add_task` / `unblock_task` 路径中，如果任务被加入远端 runqueue，并且启用了 `smp + ipi`，发送调度 IPI 到目标 CPU。wait queue 和 future wakeup 使用新的 wake selector，并在唤醒时请求 reschedule。

## Test Plan

Clean PR candidate branch:

```sh
/private/tmp/tgoskits-axtask-pr
branch: fix/axtask-smp-wakeup-progress
base: upstream/dev d3a289d12
commit: 1eeb51827 fix(axtask): kick remote CPUs on SMP wakeups
test commit: 7a0b56574 test(axtask): cover SMP remote wait-queue wakeups
PR: https://github.com/rcore-os/tgoskits/pull/926
```

This clean branch only changes:

```text
os/arceos/modules/axtask/Cargo.toml
os/arceos/modules/axtask/src/api.rs
os/arceos/modules/axtask/src/future/mod.rs
os/arceos/modules/axtask/src/run_queue.rs
os/arceos/modules/axtask/src/wait_queue.rs
test-suit/arceos/rust/task/wait_queue_remote_wake/
```

Local validation already run on the candidate worktree:

```sh
cargo fmt --check
cargo check -p ax-task --target riscv64gc-unknown-none-elf --features "multitask smp ipi"
cargo check -p arceos-wait-queue-remote-wake --target riscv64gc-unknown-none-elf --features ax-std
cargo run -p tg-xtask -- arceos test qemu --list --test-group rust --test-case task/wait_queue_remote_wake
cargo run -p tg-xtask -- arceos test qemu --arch riscv64 --test-group rust --test-case task/wait_queue_remote_wake --no-symbolize
git diff --check upstream/dev..HEAD
```

Host-native `cargo check -p ax-task --features "multitask smp ipi"` is blocked by the baseline `ax-percpu` host-aarch64 `percpu_symbol_vma!` type issue, not by this patch.

新增 test-suite：`test-suit/arceos/rust/task/wait_queue_remote_wake`。测试中 waker 固定在 CPU0，sleeper 固定在 CPU1，sleeper 进入 wait queue 后由 CPU0 远端唤醒；用快速进度检查确认不依赖后续无关 tickle 才推进。RISC-V QEMU 配置使用 `-accel tcg,thread=single`，避免 RISC-V MTTCG LR/SC 误差。

Workload evidence:

- Fingerprint no-monitor/no-tickle PASS: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-cargo-fingerprint-wave-smp8-j8-crate48-hvfopt-wakelocal-nomonitor-20260524T155852.log`
- Full StarryOS guest build PASS, `379s`: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-full-opt0-cgu256-20260524T160123.log`
- Same kernel/profile `jobs=1` control PASS, `449s`: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j1-wakelocal-full-opt0-cgu256-nomonitor-20260524T162359.log`
- Same kernel/profile `jobs=6` control PASS, `399s`: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j6-wakelocal-full-opt0-cgu256-nomonitor-20260524T211009.log`
- Same kernel/profile feature-slim `jobs=8` control PASS, `378s`: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-minfeatures-opt0-cgu256-nomonitor-20260524T214949.log`
- Clean no-monitor `jobs=8` full build PASS, `498s`: `/Users/txc/code/Auto-OS/showtime-2/logs/hvf-aarch64-starryos-smp8-j8-wakelocal-full-opt0-cgu256-nomonitor-clean-20260524T163310.log`

## Test-suite

新增 `test-suit/arceos/rust/task/wait_queue_remote_wake`，覆盖 SMP wait queue 远端唤醒路径。它不把完整 Cargo build 放进 CI，而是把问题收缩成一个稳定的内核调度/唤醒用例：

- waker 绑定 CPU0。
- sleeper 绑定 CPU1。
- sleeper 在 wait queue 上睡眠。
- waker 从 CPU0 唤醒 CPU1 上的 sleeper。
- sleeper 必须在短时间内完成并打印 `All tests passed!`。

当前 riscv64 QEMU 本地已 PASS。aarch64 暂时按现有 IPI 测试的限制跳过，因为 axplat-dyn 的 send_ipi 路径仍未完全就绪。

## Remaining Risk

- 当前 patch 已经从 `/private/tmp/tgoskits-hvf-opt` 拆到干净 `upstream/dev` 分支，未混入 FS/allocator 实验改动；test-suite 已补。PR #926 已从 draft 标为 ready，当前 `mergeable=MERGEABLE`，`mergeStateStatus=CLEAN`，GitHub Actions 全部完成，format/sync-lint/clippy/std/Starry/ArceOS container QEMU/axvisor/self-hosted board checks 均为 SUCCESS 或预期 SKIPPED。
- 完整 self-build 的速度改善是 `951/379 = 2.51x`，严格同 kernel/profile jobs speedup 是 `449/379 = 1.18x`；这个 PR 的主张应是修复 SMP wakeup 前进性，不应包装成 4x 性能 PR。
