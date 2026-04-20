# StarryOS 现状评估（自我编译视角）

**评估时间**：2026-04-19，基于 PIN `c7e88fb3`（rcore-os/tgoskits dev）+ 我们的 T1-T5 集成。

**关键判断**：StarryOS 是一个"**Linux 兼容表面写得很完整，但深度严重不足**"的内核。能 boot 进 BusyBox shell 提示符，但**用户态进程创建链路有死锁**——只能跑 shell builtin，跑不了外部程序（包括 `ls`）。

## 一、能做到的（实测✅）

### 系统层
- 4 架构 kernel build：x86_64 / riscv64 / aarch64 / loongarch64（host cargo build 全过）
- 双架构 boot 进 OpenSBI/UEFI → axplat → ax-task 调度起来 → BusyBox shell 提示符
- 内核 ELF：riscv64 4.1 MiB / x86_64 2.3 MiB
- multitask（sched-rr）+ uspace + irq + fp-simd

### Linux ABI 表面
- **160+ syscall 入口齐全**，编号与 Linux 完全一致（用 `syscalls` crate 的 `Sysno` 枚举）
- 架构特定 syscall 正确分流（x86_64 的 `open/stat/fork/poll`，riscv 的 `riscv_flush_icache`）
- Linux raw 数据结构（`stat`, `timespec`, `sigaction`）布局兼容

### 已工作的子系统
| 子系统 | 状态 |
|---|---|
| 文件系统 | ext4 + procfs + tmpfs + devfs（mount 限于 tmpfs，T4 patch 已加 ext4） |
| 网络 | TCP/UDP via smoltcp（v4 only；T3 patch 加了 v4-mapped v6） |
| 信号 | rt_sigaction/procmask/timedwait/suspend，kill/tkill/tgkill |
| futex | WAIT/WAKE/REQUEUE/CMP_REQUEUE/WAIT_BITSET（PI 系列未实现） |
| clone/clone3 | CLONE_VM/FILES/SIGHAND/THREAD/VFORK 等都支持 |
| mmap | PRIVATE/SHARED/ANON/FIXED/POPULATE/HUGETLB |
| epoll/ppoll/pselect | 完整 |
| IPC | System V 消息队列 + 共享内存（信号量未实现） |
| pipe/eventfd/signalfd/memfd | 完整 |
| pidfd | open/getfd/send_signal 完整 |

## 二、不能做到的（实测❌）

### 🔴 阻塞所有用户程序（M1.5 实测发现）

**fork + execve + wait4 在 `/bin/sh` 内串起来时整体死锁**。

```sh
echo "..."     # ✅ builtin OK
pwd            # ✅ builtin OK
ls /           # ❌ external = fork+exec+wait → 死锁，永久挂
```

意味着：
- BusyBox 的 ash 只能跑 builtin 命令
- 任何 `cmd1 | cmd2`、`$(cmd)`、`make`、`gcc`、`cargo` 都跑不动
- 31 个 acceptance 测试一个都跑不出来

### 🔴 console RX 路径不工作

host 通过 QEMU 串口 TCP 发字节给 guest BusyBox stdin → guest 完全收不到。
- TX 工作（boot log、init.sh 输出全打出来）
- RX 不工作（无法交互调试，`echo cmd | nc 4444` 无效）

### 🟠 存在但是"假成功"（更危险）

| Syscall | 现状 | 风险 |
|---|---|---|
| `flock` | `Ok(0)` 假成功 | cargo registry 损坏（T2 已修） |
| `fcntl(F_SETLK/F_SETLKW)` | `Ok(0)` | SQLite 数据损坏（T2 已修） |
| `fcntl` 未知 cmd | `Ok(0)` | 应用收到错误成功（T2 已修） |
| `madvise` / `msync` / `mlock` | no-op | 内存释放/sync 失效 |
| `mremap` | mmap+memcpy 实现 | 大块 realloc 性能/语义错 |
| `setuid/getuid` | 永远返回 0 (root) | 权限模型完全没有 |
| `capget/capset` | 假成功 | 同上 |
| `sched_setscheduler` | `Ok(0)` 不生效 | 实时调度静默失效 |
| `getpriority` | 固定返回 20 | nice 失效 |
| `timerfd_create` | dummy fd（永不触发） | event loop 静默失效（T 第二轮已修） |
| `inotify/fanotify/userfaultfd/io_uring/perf_event/bpf` | dummy fd | 现代 Linux 程序静默失败 |
| `seccomp` | `Ok(0)` 不建立策略 | 沙箱失效 |
| `ptrace` | 完全缺失 | gdb/strace 不可用 |

### 🟠 关键缺失 syscall

`waitid` / `execveat` / `setpriority` / `getresuid` / `clock_settime` / `recvmmsg/sendmmsg` / `personality` / `mq_*` / `semget/semop/semctl`

## 三、20 项 backlog（按优先级）

### Tier-F (Foundation)：阻塞 M1.5、必须先修

| ID | 任务 | Owner | 状态 |
|---|---|---|---|
| **F-α** | starry fork+execve+wait4 死锁 | D1 | 🔴 待派 |
| **F-β** | console RX 让 stdin 工作 | D1 | 🔴 待派 |

### Tier-1 (Phase 1, 已完成)

| ID | 任务 | Owner | 状态 |
|---|---|---|---|
| T1 | 多线程 execve | D1 | ✅ patch 在集成 |
| T2 | flock + fcntl 记录锁 | D3 | ✅ patch 在集成 |
| T3 | AF_INET6 v4-mapped | D3 | ✅ patch 在集成 |
| T4 | mount ext4 + bind | D3 | ✅ patch 在集成 |
| T5 | 8MB 栈 + 4G 内存 + prlimit64 | D2 | ✅ patch 在集成 |

### Tier-2：跑 GCC/cargo 必须

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T6 | ptrace 子集（TRACEME/ATTACH/CONT/PEEKDATA/POKEDATA/GETREGS/SYSCALL） | D1 | 2000 行 |
| T7 | prctl 完善（PDEATHSIG/DUMPABLE/NO_NEW_PRIVS/TID_ADDRESS/CHILD_SUBREAPER） | D1 | 300 行 |
| T8 | procfs 真数据（self/exe / cpuinfo / meminfo / random/uuid） | D2 | 400 行 |
| T9 | 缺失 syscall（waitid / openat2 / personality / setpriority / getresuid） | D2 | 500 行 |
| T10 | rootfs-selfhost 镜像（gcc/binutils/make + Alpine musl） | D2 | 镜像构建脚本 |

### Tier-3：稳定性 + S0/S1 跑通

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T11 | futex PI（LOCK_PI/UNLOCK_PI） | D1 | 400 行 |
| T12 | S0 测试 harness（guest 编 hello.c） | D4 | CI workflow |
| T13 | x86_64 vDSO 最小集（clock_gettime/getcpu） | D1 | 700 行 |
| T14 | AddrSpace Mutex → RwLock | D1 | 300 行 |
| T15 | 信号 per-thread skip flag | D1 | 80 行 |

### Tier-4：S1/S2 cargo

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T16 | mremap 真实页表 remap | D1 | 400 行 |
| T17 | madvise（DONTNEED/FREE/REMOVE） | D1 | 250 行 |
| T18 | virtio-9p（host 源码直通） | D3 | 2000 行 |
| T19 | sysfs cpu 节点 | D2 | 150 行 |
| T20 | rust 工具链装到 selfhost rootfs | D2 | 镜像扩展 |

### Tier-5：S3/S4 自举

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T21 | AF_INET6 完整栈（smoltcp v6） | D3 | 1200 行 |
| T22 | xtask guest 兼容 | D2 | 200 行 |
| T23 | swap + 大磁盘 | D2 | 镜像 + swapon |
| T24 | S3 自举测试 + S4 reproducibility | D4 | CI workflow |

## 四、当前推进策略

### 立即推（本轮）

1. **F-α (D1)**：修 fork+exec+wait4 死锁——这一项不通，全部 Tier-1+ 的 patch 都没法在 guest 实证
2. **F-β (D1)**：修 console RX——能交互调试效率 ×10

两条**并行 fan-out**，各自独立 worktree + session。F-α 是阻塞所有 acceptance test 的硬瓶颈；F-β 是质量提升。

### F-α 修完后

3. 重跑 M1.5（已有 patch + scripts），拿到 31 测试真 PASS 数
4. 根据 PASS 数：
   - 大量 PASS → 启动 Tier-2 fan-out（T6/T7/T8/T9/T10）
   - 大量 FAIL → 给原 subagent 派 follow-up 修对应 patch

### Tier-2 完成后

5. 制作 selfhost rootfs 镜像（含 musl-gcc + binutils + make）
6. 跑 M2 = guest 内 `cc hello.c -o hello && ./hello`（S0 出口）

### 最长路径

```
F-α + F-β  →  M1.5 重做  →  T6-T10  →  rootfs 镜像  →  M2  →  M3 (BusyBox)  →  M4-M5 (cargo)  →  M6 (自举 kernel)
   ↑ 现在卡在这                                                                        ← 终态
```

## 五、给后续 Director 的建议

1. **不要再 fan-out 任何 syscall 实现 patch（T6+）直到 F-α 修好**——没法验证就只能信 subagent 自报
2. **CI 一定要在 GitHub Actions 跑 build + sanity-check**，不要只跑文档 lint
3. **subagent prompt 必须强制要求跑 `bash scripts/integration-build.sh`**——这次 T1/T2/T4/T5 4 个 subagent 都自报 build SKIP 但实际全 fail
4. **session resume 真的好用**，但 cursor-agent CLI 自己有 `--print` 模式 stream-json 中段截断的 bug，要用 tmux 包一层避免被 Shell tool 超时杀掉

## 文档索引

- `selfhost-orchestrator/COMPILE-MILESTONES.md` — 每个 Phase 的"小编译目标"
- `selfhost-orchestrator/ROADMAP.md` — 6 阶段路线 + 7 checkpoint
- `selfhost-orchestrator/ROLES.md` — D0-D4 五岗位
- `selfhost-orchestrator/TEST-MATRIX.md` / `DETAILED-TEST-MATRIX.md` — syscall × case 测试矩阵
- `selfhost-orchestrator/PROCESS-LOG.md` — 实时开发日志
- `patches/integration/CONFLICTS.md` — Phase 1 集成手工解冲突方案
- `docs/M1.5-results.md` — 第二轮验收报告 + Followup
- 本文 `docs/STARRYOS-STATUS.md` — 现状 + 20 项 backlog
