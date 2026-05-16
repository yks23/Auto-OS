# StarryOS 最小 Cargo 编译宿主 syscall 覆盖静态分析

> 结论边界：本报告的 syscall 清单来自 Linux 宿主 Docker 内 `strace`，只作为“宿主参考/静态覆盖清单”。它不是 Starry 访客内 `/proc/syscall_stats` 的真实运行数据。

## 证据与环境

- 证据目录：`.guest-runs/host-strace-minicrate-20260511T074602Z`
- 完整日志：`.guest-runs/host-strace-minicrate-20260511T074602Z/strace-full.log`
- 汇总表：`.guest-runs/host-strace-minicrate-20260511T074602Z/strace-summary.txt`
- 去重清单：`.guest-runs/host-strace-minicrate-20260511T074602Z/syscalls.txt`
- 机器环境：`.guest-runs/host-strace-minicrate-20260511T074602Z/env.txt`
- 测试 crate：临时 hello-world 级最小 binary crate，无依赖，`cargo build --offline`。
- 容器镜像：`auto-os/starry:latest`；容器内缺少 `strace` 时用 apt 安装。

执行命令核心形态：

```bash
strace -f -o strace-full.log -- cargo build --offline
cargo clean
strace -f -c -o strace-summary.txt -- cargo build --offline
```

环境摘要：

```text
date_utc=2026-05-11T07:47:06Z
image=auto-os/starry:latest
uname=Linux 38c3d0432245 6.12.76-linuxkit #1 SMP Sun Mar  8 14:41:59 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
rustc=rustc 1.96.0-nightly (48cc71ee8 2026-03-31)
cargo=cargo 1.96.0-nightly (888f67534 2026-03-30)
strace=strace -- version 6.8
```

## syscall Top 表

| 排名 | syscall | calls | errors |
| ---: | --- | ---: | ---: |
| 1 | `lseek` | 7420 | 4 |
| 2 | `read` | 3303 | 8 |
| 3 | `readlinkat` | 1521 | 1506 |
| 4 | `write` | 1301 | 0 |
| 5 | `futex` | 1096 | 6 |
| 6 | `openat` | 440 | 176 |
| 7 | `mmap` | 414 | 0 |
| 8 | `close` | 290 | 0 |
| 9 | `newfstatat` | 287 | 174 |
| 10 | `rt_sigaction` | 275 | 0 |
| 11 | `fstat` | 252 | 0 |
| 12 | `statx` | 230 | 58 |
| 13 | `munmap` | 205 | 0 |
| 14 | `mprotect` | 188 | 0 |
| 15 | `brk` | 177 | 0 |
| 16 | `fcntl` | 114 | 0 |
| 17 | `rt_sigprocmask` | 94 | 0 |
| 18 | `faccessat` | 76 | 50 |
| 19 | `sigaltstack` | 70 | 0 |
| 20 | `ioctl` | 61 | 49 |
| 21 | `madvise` | 56 | 0 |
| 22 | `prlimit64` | 37 | 0 |
| 23 | `sched_getaffinity` | 34 | 0 |
| 24 | `set_robust_list` | 32 | 0 |
| 25 | `rseq` | 30 | 0 |
| 26 | `clone` | 28 | 0 |
| 27 | `dup` | 28 | 0 |
| 28 | `getcwd` | 28 | 0 |
| 29 | `gettid` | 27 | 0 |
| 30 | `getrandom` | 22 | 0 |

总计：`strace -c` 汇总 `18361` 次 syscall，去重 `66` 个 syscall。

## 去重 syscall 名单

`lseek`, `read`, `readlinkat`, `write`, `futex`, `openat`, `mmap`, `close`, `newfstatat`, `rt_sigaction`, `fstat`, `statx`, `munmap`, `mprotect`, `brk`, `fcntl`, `rt_sigprocmask`, `faccessat`, `sigaltstack`, `ioctl`, `madvise`, `prlimit64`, `sched_getaffinity`, `set_robust_list`, `rseq`, `clone`, `dup`, `getcwd`, `gettid`, `getrandom`, `ppoll`, `execve`, `flock`, `getpid`, `prctl`, `dup3`, `mkdirat`, `pipe2`, `getdents64`, `statfs`, `unlinkat`, `clone3`, `set_tid_address`, `wait4`, `uname`, `faccessat2`, `geteuid`, `getuid`, `socketpair`, `pread64`, `recvfrom`, `umask`, `chdir`, `epoll_create1`, `epoll_ctl`, `eventfd2`, `fchmodat`, `getrusage`, `linkat`, `renameat`, `restart_syscall`, `rt_sigreturn`, `sched_yield`, `socket`, `tgkill`, `utimensat`

## StarryOS 覆盖矩阵

静态检查范围：`tgoskits/os/StarryOS/kernel/src/syscall`，重点查看 `mod.rs` 分发与对应实现文件。状态含义：`已实现` 表示有明确分发与主体逻辑；`部分` 表示常用路径存在但源码显示限制/TODO/错误语义风险；`stub` 表示基本 no-op；`缺失` 表示当前 riscv64 分发中不可达或未分发。

| syscall | calls | errors | StarryOS 状态 | 风险 | 依据 |
| --- | ---: | ---: | --- | --- | --- |
| `lseek` | 7420 | 4 | 已实现 | 中 | `fs/io.rs` regular file seek；pipe/socket 返回 ESPIPE 路径已处理。 |
| `read` | 3303 | 8 | 已实现 | 中 | `fs/io.rs` 走 FileLike::read。 |
| `readlinkat` | 1521 | 1506 | 已实现 | 中 | `fs/ctl.rs` resolve_no_follow + read_link。 |
| `write` | 1301 | 0 | 已实现 | 中 | `fs/io.rs` 走 FileLike::write。 |
| `futex` | 1096 | 6 | 部分 | 高 | 支持 WAIT/WAIT_BITSET/WAKE/WAKE_BITSET/REQUEUE/CMP_REQUEUE；其它 futex op 返回 Unsupported。Rust 线程/锁路径高频依赖。 |
| `openat` | 440 | 176 | 已实现 | 高 | `fs/fd_ops.rs` 支持常见 open flags、O_CLOEXEC/O_NONBLOCK/O_DIRECTORY/O_NOFOLLOW 等。 |
| `mmap` | 414 | 0 | 部分 | 高 | 支持匿名、文件、设备、MAP_FIXED/NOREPLACE/POPULATE 等基本路径；仍有非法 flags、file mmap page size、huge/边界语义 TODO。 |
| `close` | 290 | 0 | 已实现 | 中 | `fs/fd_ops.rs` close_file_like。 |
| `newfstatat` | 287 | 174 | 已实现 | 高 | `fs/stat.rs` 走 resolve_at + stat。 |
| `rt_sigaction` | 275 | 0 | 已实现 | 中 | `signal.rs` set_action，SIGKILL/SIGSTOP 拒绝。 |
| `fstat` | 252 | 0 | 已实现 | 高 | `fs/stat.rs` 复用 fstatat(AT_EMPTY_PATH)。 |
| `statx` | 230 | 58 | 部分 | 高 | `fs/stat.rs` 可写 statx；mask 未细分，路径 flags 依赖 resolve_at。 |
| `munmap` | 205 | 0 | 已实现 | 高 | `mm/mmap.rs` unmap aligned length。 |
| `mprotect` | 188 | 0 | 部分 | 高 | 支持基本保护位；PROT_GROWSUP/GROWSDOWN 未实现并返回 EINVAL。 |
| `brk` | 177 | 0 | 已实现 | 高 | `mm/brk.rs` 支持 heap 扩缩与 RLIMIT_DATA。 |
| `fcntl` | 114 | 0 | 部分 | 高 | 支持 F_DUPFD、FD_CLOEXEC、GET/SETFL、record/OFD locks、pipe size 等；其它 cmd 返回 EINVAL。 |
| `rt_sigprocmask` | 94 | 0 | 已实现 | 中 | `signal.rs` 支持 BLOCK/UNBLOCK/SETMASK。 |
| `faccessat` | 76 | 50 | 部分 | 中 | 分发到 faccessat2；权限判断较简化，主要按 owner mode 位。 |
| `sigaltstack` | 70 | 0 | 已实现 | 中 | `signal.rs` 支持设置/读取 alternate signal stack。 |
| `ioctl` | 61 | 49 | 部分 | 高 | 仅通用 FIONBIO 与底层 device ioctl；大量 tty/文件 ioctl 可能 NotATty/Unsupported。 |
| `madvise` | 56 | 0 | stub | 中 | `mm/mmap.rs` 直接 Ok(0)，不执行 advice。 |
| `prlimit64` | 37 | 0 | 部分 | 中 | 仅允许当前进程；RLIMIT_NOFILE 有 Starry 上限裁剪。 |
| `sched_getaffinity` | 34 | 0 | 部分 | 中 | 仅 pid=0；其它 pid 返回 EPERM。 |
| `set_robust_list` | 32 | 0 | 已实现 | 中 | `sync/futex.rs` 保存 robust_list head。 |
| `rseq` | 30 | 0 | 部分 | 高 | 最小注册/注销，只保存地址，不实现完整 restartable sequences 语义。 |
| `clone` | 28 | 0 | 部分 | 高 | 支持进程/线程 clone 主路径；namespace flags 仅警告 stub，部分组合受限。 |
| `dup` | 28 | 0 | 已实现 | 中 | `fs/fd_ops.rs` dup_fd。 |
| `getcwd` | 28 | 0 | 部分 | 低 | 返回 buf 指针；源码注释提示返回值语义 FIXME。 |
| `gettid` | 27 | 0 | 已实现 | 中 | `task/thread.rs` 返回当前 task id。 |
| `getrandom` | 22 | 0 | 已实现 | 中 | `sys.rs` 从 /dev/random 或 /dev/urandom 读取。 |
| `ppoll` | 19 | 0 | 部分 | 高 | poll 主逻辑可用；源码 TODO: handle signal。 |
| `execve` | 18 | 9 | 已实现 | 高 | `task/execve.rs` 支持加载新镜像、CLOEXEC、vfork detach。 |
| `flock` | 18 | 0 | 已实现 | 中 | `fs/fd_ops.rs` flock_inode。 |
| `getpid` | 17 | 0 | 已实现 | 低 | `task/thread.rs` 返回进程 pid。 |
| `prctl` | 16 | 0 | 部分 | 高 | 仅 PR_SET_NAME/GET_NAME/SET_SECCOMP(no-op)/MCE_KILL/PR_SET_MM EINVAL；其它 EINVAL。 |
| `dup3` | 14 | 0 | 已实现 | 中 | `fs/fd_ops.rs` 支持 O_CLOEXEC。 |
| `mkdirat` | 14 | 3 | 已实现 | 中 | `fs/ctl.rs` create_dir + umask。 |
| `pipe2` | 14 | 0 | 部分 | 中 | 支持 O_CLOEXEC/O_NONBLOCK；未知 flags 被 truncate 并告警，非严格 Linux 语义。 |
| `getdents64` | 12 | 0 | 已实现 | 中 | `fs/ctl.rs` 目录项写出。 |
| `statfs` | 11 | 0 | 部分 | 低 | 基本 statfs；fsid 有 TODO。 |
| `unlinkat` | 11 | 1 | 已实现 | 中 | `fs/ctl.rs` 支持 remove file/dir。 |
| `clone3` | 9 | 9 | 部分 | 中 | 有实现；set_tid/cgroup 忽略，复杂 flag 组合受限。strace 中 9 次均为错误返回。 |
| `set_tid_address` | 9 | 0 | 已实现 | 中 | `task/thread.rs` 设置 clear_child_tid。 |
| `wait4` | 7 | 0 | 部分 | 高 | `task/wait.rs` waitpid 主路径；WALL/WCLONE 支持有 FIXME。 |
| `uname` | 4 | 0 | 已实现 | 低 | `sys.rs` 固定 UTSNAME。 |
| `faccessat2` | 3 | 0 | 部分 | 中 | 权限判断较简化，主要按 owner mode 位。 |
| `geteuid` | 3 | 0 | 已实现 | 低 | `sys.rs` 返回 res_uids.euid。 |
| `getuid` | 3 | 0 | 已实现 | 低 | `sys.rs` 返回 res_uids.ruid。 |
| `socketpair` | 3 | 0 | 已实现 | 中 | `net/socket.rs` 支持 AF_UNIX stream/dgram/seqpacket。 |
| `pread64` | 2 | 0 | 已实现 | 中 | `fs/io.rs` read_at。 |
| `recvfrom` | 2 | 0 | 已实现 | 中 | `net/io.rs` recv_impl。 |
| `umask` | 2 | 0 | 已实现 | 低 | `task/ctl.rs` 保存/返回 umask。 |
| `chdir` | 1 | 0 | 已实现 | 低 | `fs/ctl.rs` set_current_dir。 |
| `epoll_create1` | 1 | 0 | 已实现 | 高 | `io_mpx/epoll.rs` 支持 CLOEXEC。 |
| `epoll_ctl` | 1 | 0 | 已实现 | 高 | `io_mpx/epoll.rs` add/mod/del。 |
| `eventfd2` | 1 | 0 | 已实现 | 高 | `fs/event.rs` 支持 CLOEXEC/NONBLOCK/SEMAPHORE。 |
| `fchmodat` | 1 | 0 | 已实现 | 低 | `fs/ctl.rs` update_metadata mode。 |
| `getrusage` | 1 | 0 | 部分 | 低 | 仅填 utime/stime，rusage 其它字段为零。 |
| `linkat` | 1 | 0 | 部分 | 低 | 基本 hard link；非零 flags 仅告警后继续。 |
| `renameat` | 1 | 0 | 缺失(riscv64) | 中 | `handle_syscall` 中 renameat 对 riscv64 被 cfg 排除；仅 renameat2 分发。宿主 aarch64 参考出现 1 次。 |
| `restart_syscall` | 1 | 0 | 缺失 | 中 | `handle_syscall` 未分发 restart_syscall；若访客用户态触发会 ENOSYS/Unsupported。 |
| `rt_sigreturn` | 1 | 1 | 已实现 | 中 | `signal.rs` restore signal frame。 |
| `sched_yield` | 1 | 0 | 已实现 | 低 | `task/schedule.rs` yield_now。 |
| `socket` | 1 | 0 | 已实现 | 中 | `net/socket.rs` 支持 AF_INET/AF_INET6/AF_UNIX 常用类型。 |
| `tgkill` | 1 | 0 | 已实现 | 中 | `signal.rs` send_signal_to_thread。 |
| `utimensat` | 1 | 0 | 已实现 | 低 | `fs/ctl.rs` 支持 UTIME_NOW/OMIT 和 AT_EMPTY_PATH。 |

## 汇总判断

- 66 个宿主参考 syscall 中，静态判断 `已实现` 42 个，`部分/stub` 22 个，`缺失` 2 个。
- 高频路径的主要风险不在“完全没有分发”，而在 Linux 语义完整度：`futex`、`mmap/mprotect`、`fcntl/flock`、`clone/execve/wait4`、`ppoll/epoll/eventfd`、`statx/openat`、`ioctl`。
- 明确缺口是 `restart_syscall` 未分发，以及 `renameat` 在 riscv64 下被 cfg 排除；如果目标访客用户态也触发这些 syscall，会走未实现分支。
- `madvise` 是 no-op stub；多数 Rust/Cargo 场景可能容忍，但这不能视为完整实现。`rseq`、`prctl`、`clone3`、`sched_getaffinity` 属于最小兼容实现，需结合访客真实日志验证。

## 优先修复建议

1. 优先补齐会直接影响 Rust/Cargo 并发与进程生命周期的高风险项：扩展 `futex` op 覆盖，审计 `clone/clone3` flag 组合、`execve` vfork 语义、`wait4` 的 `WALL/WCLONE` 行为。
2. 补 `restart_syscall` 与 riscv64 `renameat` 兼容分发；即使先转发到现有逻辑或返回可预期错误，也应避免静默落入通用 unsupported。
3. 针对文件系统密集路径做专项测试：`openat`、`newfstatat/statx`、`readlinkat`、`fcntl/flock`、`mmap` 文件映射，覆盖 Cargo/rustc 常见错误返回。
4. 把 `ioctl`、`prctl`、`rseq`、`madvise` 明确分层：哪些是可接受 no-op，哪些必须返回 Linux 兼容错误，哪些需要真实语义。
5. 后续若要判断 StarryOS 真实运行情况，应在 QEMU 访客串口中采集 `/proc/syscall_stats` 的 `===SYSCALL_STATS_BEGIN===` 块，不能用本宿主 `strace` 结果替代。
