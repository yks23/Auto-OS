# fix(starry): avoid teardown usercopy from kernel tasks

## 问题 / Root Cause

StarryOS 的退出清理路径会处理 robust futex list 和 `clear_child_tid`。旧实现里，teardown 路径通过 `current().as_thread()` 推导当前线程、地址空间和 futex table；一旦清理发生在非用户线程上下文，或者用户内存访问递归撞到当前地址空间锁，就会把“用户态上下文假设”带进内核任务路径，可能触发 `kernel task` panic、错误的 futex table 查找，或 page-fault/usercopy 重入。

这在 M6 guest cargo 并发编译中容易出现：大量 rustc 进程退出、wait、futex cleanup 和用户缓冲区访问交叠，错误会晚于启动阶段暴露，反馈链路很长。

## Fix Summary

- 用户内存 region/string 检查先确认当前任务确实是用户线程；非线程上下文返回 `EFAULT`/`AccessDenied`，不再 panic。
- page fault 处理前检查当前地址空间锁是否已被持有，避免递归锁路径进入 `might_sleep()` panic。
- robust futex teardown 改为显式传入正在退出的 `Thread`，owner TID、`ProcessData`、private futex table 都从退出线程取得。
- `clear_child_tid` 唤醒同样绑定退出线程的 `ProcessData`，避免使用当前 CPU 上的临时任务上下文。
- `AsThread::as_thread()` 增加 `#[track_caller]`，后续若还有错误上下文会直接指向调用点。

## 为什么改这些地方

- `mm/access.rs` 是 StarryOS 用户指针读写和 page fault 的统一入口，适合统一拒绝非线程上下文的 usercopy。
- `task/futex.rs` 是 futex key/table 选择处，需要提供“已知进程上下文”的 teardown 版本。
- `task/ops.rs` 是 `do_exit` / robust-list / clear-child-tid 的拥有者，修复必须围绕退出线程本身。
- `task/mod.rs` 的 `track_caller` 只用于后续诊断，不改变行为。

## Test Plan

- `git diff --check upstream/dev...HEAD`
- `cargo fmt --check`
- 现有 test-suite 覆盖：
  - `test-suit/starryos/normal/qemu-smp1/syscall/test-futex-robust-list`
  - `test-suit/starryos/normal/qemu-smp1/test-mt-execve`
- M6 证据：
  - 后续 8 核/8 job guest cargo self-build 使用该类修复作为并发退出/futex/usercopy 路径验证。

## Remaining Risk

本地 macOS host 上 `cargo xtask clippy --package starry-kernel` 触发既有 Mach-O/percpu section baseline 问题，未能作为本 PR 的有效信号；CI Linux 环境需要补跑完整 StarryOS qemu tests。
