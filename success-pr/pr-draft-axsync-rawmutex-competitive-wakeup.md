# fix(axsync): release raw mutex before waking waiter

## 问题 / Root Cause

SMP 下 `RawMutex::unlock` 旧逻辑用 `notify_one_with` 把 `owner_id` 直接切到等待者。这个“直接 handoff”在竞争环境里不安全：被唤醒任务真正拿到 guard 前，owner 状态已经指向它；如果该任务重新进入同一把锁，会被判定为“已经拥有 mutex”，触发自拥有 panic。

M6 guest cargo 并发编译会高频触发地址空间锁、page cache、进程退出和 futex wait/wake，这类锁 handoff 竞态会把编译推进卡在很晚的位置。

## Fix Summary

- `RawMutex::unlock` 先用 `Release` 把 `owner_id` 清零，再唤醒一个等待者。
- 等待者醒来后仍走 CAS acquire 路径，真正成功拿锁后才成为 owner。
- guard marker 改成 `GuardNoSend`，避免 mutex guard 被跨任务/线程转移后破坏 owner 语义。
- 增加 `qemu-smp4/test-rawmutex-handoff` 回归：4 个 worker 并发执行 `mmap`、fault、`mprotect`、`munmap`，持续压测地址空间锁竞争。

## 为什么改这些地方

- `os/arceos/modules/axsync/src/mutex.rs` 是 sleepable mutex 的核心实现，问题是锁语义而不是某个 syscall 脚本。
- `test-suit/starryos/normal/qemu-smp4/test-rawmutex-handoff` 专门覆盖 SMP 竞争场景，比单核 syscall case 更贴近 M6 暴露的失败形态。
- RISC-V qemu 配置保留 `-accel tcg,thread=single`，因为 QEMU RISC-V MTTCG 的 LR/SC 模拟不能作为正确性证明；速度实验另行记录。

## Test Plan

- `git diff --check upstream/dev...HEAD`
- `cargo fmt --check`
- test-suite 新增：
  - `cargo xtask starry test qemu --arch riscv64 -g normal -c test-rawmutex-handoff`
  - 同目录提供 aarch64 / loongarch64 / x86_64 配置，CI 可按架构发现。

## Remaining Risk

本地 macOS host 上 `cargo xtask clippy --package ax-sync` 触发既有 Mach-O/percpu section baseline 问题，未能作为本 PR 的有效信号；需要以 Linux CI 和 qemu-smp4 testsuite 结果为准。
