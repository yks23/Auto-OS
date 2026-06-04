# StarryOS minicrate cargo syscall 静态审计

> 边界：本文基于 Linux Docker host `strace` 的 syscall 与参数模式，只作为静态语义参考；它不是 Starry 访客内真实 `/proc/syscall_stats` 数据。

## 证据

- 覆盖报告：`docs/STARRYOS-HOST-MINICRATE-SYSCALL-COVERAGE.md`
- strace 目录：`.guest-runs/host-strace-minicrate-20260511T074602Z/`
- 完整日志：`.guest-runs/host-strace-minicrate-20260511T074602Z/strace-full.log`
- 汇总表：`.guest-runs/host-strace-minicrate-20260511T074602Z/strace-summary.txt`

## 关键参数模式

- `wait4`：`7` 次调用耗时占比最高，用于 cargo 等待 rustc/子进程；guest 循环中已越过此前 `wait4(pid=rustc)` 问题，后续仍在读 pipe/path/time 路径消耗时间。
- `pipe2/dup3/fcntl/close/read`：`pipe2([r,w], O_CLOEXEC)` 创建 rustc stdout/stderr 管道；子进程使用 `dup3(pipe_write, 1/2, 0)`；父进程对读端做 `F_GETFL`、`F_SETFL O_NONBLOCK`、再恢复阻塞；rustc 结束后依赖写端关闭触发读端 EOF/HUP。
- `FD_CLOEXEC`：`pipe2(O_CLOEXEC)` 后子进程会对部分 fd 执行 `F_GETFD`/`F_SETFD` 清除或设置 `FD_CLOEXEC`；`execve` 必须按 fd 表状态关闭 cloexec fd。
- `F_DUPFD_CLOEXEC`：出现 `fcntl(3, F_DUPFD_CLOEXEC, 3) = 5`，Linux 语义要求分配最低可用且 `>= arg` 的 fd，而不是全局最低 fd。
- `statx/newfstatat/readlinkat/openat`：大量 `statx(..., AT_STATX_SYNC_AS_STAT, STATX_ALL, ...)`、`statx(fd, "", AT_EMPTY_PATH, STATX_ALL, ...)`、不存在路径返回 `ENOENT`；普通目录/文件 `readlinkat` 返回 `EINVAL`，不存在组件返回 `ENOENT`，`/proc/self/exe` 返回目标路径。
- `ppoll`：两类模式，一类是 `{fd=0,1,2 events=0}` 加零超时探测并返回 `0`，另一类是对 rustc stdout/stderr 管道读端 `POLLIN` 无限等待。
- `ioctl`：cargo/rustc 对 stdout/stderr 和普通文件 fd 调 `TCGETS`，Linux 对非 tty 返回 `ENOTTY`。
- `clock_gettime/nanosleep`：本次汇总里 `clock_gettime` 不在 top 表但 guest timeout 后仍值得核对；当前实现支持常见 realtime/monotonic/process/thread clock，未知 clock 仍降级成功，语义偏宽。

## 语义组审计

| 组 | Linux 期望 / strace 模式 | Starry 当前行为 | 风险 | 本轮处理 |
| --- | --- | --- | --- | --- |
| pipe/fd 生命周期 | `pipe2(O_CLOEXEC)`、`dup3` 重定向、父进程读端 `F_SETFL O_NONBLOCK` 探测、写端关闭后读端 EOF/HUP | pipe 读空且写端关闭返回 `0`；poll 对读端设置 `IN|HUP`；execve 已关闭 cloexec fd | `F_DUPFD*` 未按 arg 下界分配会扰乱 fd 布局；`pipe2` 曾截断未知 flags，可能把非法调用误当成功 | 已修 `F_DUPFD/F_DUPFD_CLOEXEC` 下界语义，`dup3` 负 fd 返回 `EBADF`，`pipe2` 未知 flags 返回 `EINVAL` |
| fd flags | `F_GETFD/F_SETFD` 操作 `FD_CLOEXEC`；`F_GETFL/F_SETFL` 主要切 `O_NONBLOCK` | `FD_CLOEXEC` 保存在 fd 表；`F_SETFL` 支持 nonblock；`F_GETFL` 会按读写权限合成访问模式 | `F_GETFL` 不能恢复完整 open flags，如 `O_DIRECTORY/O_NOFOLLOW/O_LARGEFILE`，但 cargo 关键路径主要只读 `O_NONBLOCK` | 记录风险，未扩展 open flag 持久化，避免跨文件系统大改 |
| path/stat | `statx(... STATX_ALL ...)` 成功时 Linux 返回 `stx_mask=STATX_*|STATX_MNT_ID` 且 `stx_attributes=0`；`AT_EMPTY_PATH` 高频 | `statx` 写出基本字段，但 `stx_mask` 之前为 0，`stx_attributes` 误用 mode | 用户态可能把成功 statx 当“不含有效字段”，或误判 attributes | 已补 `stx_mask=STATX_BASIC_STATS|STATX_MNT_ID`，清零 `stx_attributes/stx_attributes_mask` |
| readlinkat | 普通路径返回 `EINVAL`，不存在返回 `ENOENT`，`/proc/self/exe` 返回 exe 路径且不写 NUL | 走 `resolve_no_follow + read_link`，由 VFS 决定 `EINVAL/ENOENT`；proc exe 行为需结合 procfs 验证 | 高频错误返回如果错成 `ENOSYS`/`EFAULT` 会破坏 rustup/cargo 路径探测 | 本轮未改，优先保守记录 |
| ppoll/poll | 零超时返回 `0`；管道读端阻塞直到 `POLLIN/HUP`；非法 fd 置 `POLLNVAL` | `do_poll` 支持 timeout、`POLLNVAL`、管道 `IN/HUP`；signal mask 仅做阻塞切换，注释仍有 signal TODO | 若信号打断/剩余时间语义不准，可能影响取消或超时，不是当前 EOF 嫌疑第一位 | 本轮未改，建议后续专项补 EINTR/信号唤醒 |
| ioctl tty | `TCGETS` 对非 tty 返回 `ENOTTY` | `FileLike::ioctl` 默认 `NotATty`，pipe 也对未知 ioctl 返回 `NotATty` | 对真实 tty 的结构体填充需另测；非 tty 探测路径已匹配 | 本轮未改 |
| renameat/restart_syscall | host 参考出现 `renameat` 和 `restart_syscall` | 覆盖报告显示 riscv64 `renameat` 分发受 cfg 限制，`restart_syscall` 未分发 | 如果 guest 用户态触发会落到 unsupported；但 riscv64 syscall 表和 ABI 需先确认 | 本轮未冒险修改分发 |
| mmap/mprotect/madvise/rseq/prctl | rustc 高频依赖 mmap/mprotect；`madvise` 多为可容忍 hint，`rseq/prctl` 常见最小兼容 | 已有部分实现或 no-op | 语义面大，错误返回比 no-op 更容易破坏用户态 | 本轮仅记录，建议单独审计 |

## 本轮代码修复

- `tgoskits/os/StarryOS/kernel/src/file/mod.rs`
  - 新增按最小 fd 下界分配的 `add_file_like_from`。
  - `statx` 转换补 `stx_mask=STATX_BASIC_STATS|STATX_MNT_ID`，不再把 mode 写入 `stx_attributes`。
- `tgoskits/os/StarryOS/kernel/src/syscall/fs/fd_ops.rs`
  - `F_DUPFD`/`F_DUPFD_CLOEXEC` 改为分配最低可用且 `>= arg` 的 fd。
  - `dup3` 对负 `old_fd/new_fd` 先返回 `EBADF`，避免负数转巨大 `usize` 后路径不清。
- `tgoskits/os/StarryOS/kernel/src/syscall/fs/pipe.rs`
  - `pipe2` 对非 `O_CLOEXEC|O_NONBLOCK` flags 返回 `EINVAL`，匹配 Linux 行为。

## 后续建议

1. 下一组优先补 `F_GETFL` 的 open flag 持久化，至少让 regular file/dir 能返回 `O_DIRECTORY/O_NOFOLLOW/O_APPEND/O_CLOEXEC` 之外的状态位边界清晰；这需要在 `FileLike` 或 fd 描述符层保存 open flags。
2. 然后补 `ppoll` 的 signal/EINTR 语义和管道关闭唤醒专项测试，适合用小型用户态测试先静态验证。
3. `readlinkat("/proc/self/exe")` 和 `statx(AT_EMPTY_PATH)` 应补 targeted test；这组通过后再跑一次短 guest onecrate，而不是每个小补丁都等长 QEMU。
