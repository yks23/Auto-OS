# 角色与岗位（Roles）— 在 Auto-OS 仓内闭环

5 个角色（D0-D4），其中 D1-D4 由 cursor-agent subagent 实例承担，由 dispatcher 派发。每个 subagent 拿到一份"任务包合同"（`tasks/Tn-*.md`），在自己的 git worktree 里干活，输出 patches。

## D0：Director（总开发师）

**当前 owner**：cursor cloud agent（即本会话）

**职责**：
1. 维护 `ROADMAP.md` / `ROLES.md` / `TEST-MATRIX.md` / `PROCESS-LOG.md` / `tasks/T*.md`。
2. 维护 `dispatcher.py` 与 `scripts/*.sh` 工具链。
3. Review 所有子 agent 提交的 PR；强制 acceptance criteria 自检表与测试用例。
4. 维护 `PIN.toml`，决策 pin 升级时机与冲突解决。
5. 周期性看 CI 状态，修复 workflow / 测试基础设施 bug。
6. 跟 Phase Exit Criteria 决策 phase 推进。

**工具**：
- `cursor-agent` CLI（fan-out subagent）
- `gh` CLI（read-only）
- `ManagePullRequest` MCP（开/更 PR）
- `git worktree`、`git format-patch`、`git am`

---

## D1：Kernel Core 工程师

**领域**：syscall 入口、task/thread、信号、内存、ptrace、futex、TLS、vDSO。

| Phase | 主任务 |
|---|---|
| 1 | T1 多线程 execve + execveat |
| 2 | T6 ptrace 子集、T7 prctl 完善、T11 futex PI（可选） |
| 3 | T13 x86_64 vDSO、T14 AddrSpace Mutex→RwLock |
| 4 | T15 信号 per-thread、T16 mremap、T17 madvise |

**主写文件**：
- `tgoskits/os/StarryOS/kernel/src/syscall/task/{execve,clone,wait,schedule,thread}.rs`
- `tgoskits/os/StarryOS/kernel/src/syscall/sync/futex.rs`
- `tgoskits/os/StarryOS/kernel/src/task/{signal,user,mod}.rs`
- `tgoskits/os/StarryOS/kernel/src/syscall/mm/{mmap,mprotect,mremap}.rs`
- `tgoskits/os/StarryOS/kernel/src/syscall/mod.rs`（仅加新 syscall arm）

**输出**：
- 1 个 Auto-OS 仓的工作分支
- `patches/Tn-slug/0001-...patch …`
- `patches/Tn-slug/META.toml` + `README.md`
- `tests/selfhost/test_<task>_*.c`
- 1 个 PR（base=main, head=cursor/selfhost-...-7c9d）
- PR body 含 acceptance criteria 自检表 + 测试运行截图/日志

---

## D2：Resource & Build 工程师

**领域**：资源限制、配置常量、Makefile、xtask、procfs/sysfs、rootfs 镜像、CI。

| Phase | 主任务 |
|---|---|
| 1 | T5 用户栈/QEMU/FD 上限 + prlimit64 真实生效 |
| 2 | T8 procfs 关键节点、T9 缺失 syscall、T10 rootfs-selfhost 镜像 |
| 4 | T19 sysfs cpu 节点 |
| 5 | T21 rootfs 加 rust 工具链 |
| 6 | T24 xtask guest 兼容、T25 swap 与大磁盘 |

**主写文件**：
- `tgoskits/os/StarryOS/kernel/src/config/*.rs`
- `tgoskits/os/StarryOS/kernel/src/pseudofs/{proc,sys}/`
- `tgoskits/os/StarryOS/kernel/src/syscall/task/{rlimit,thread}.rs`
- `tgoskits/os/StarryOS/Makefile`、`make/*.mk`、`xtask/`
- Auto-OS 仓内 `scripts/build-selfhost-rootfs/`、`scripts/run-guest-cargo.sh` 等

---

## D3：FS & Net 工程师

**领域**：VFS、文件锁、mount、网络栈、socket、virtio-9p。

| Phase | 主任务 |
|---|---|
| 1 | T2 flock + fcntl 记录锁、T3 AF_INET6（v4-mapped）、T4 mount ext4 + bind |
| 4 | T18 virtio-9p 完整版 |
| 5 | T22 AF_INET6 完整栈（smoltcp v6） |

**主写文件**：
- `tgoskits/os/StarryOS/kernel/src/file/{flock,record_lock,fs,mod}.rs`
- `tgoskits/os/StarryOS/kernel/src/syscall/fs/{mount,fd_ops}.rs`
- `tgoskits/os/StarryOS/kernel/src/syscall/net/{socket,addr,opt}.rs`
- `tgoskits/components/`（virtio-9p 驱动）

---

## D4：Test & CI 工程师

**领域**：测试用例、CI workflow、自我编译里程碑验证、selfhost rootfs 工具链测试。

| Phase | 主任务 |
|---|---|
| 1 | 准备 `tests/selfhost/` 完整骨架；为 T1-T5 各写 acceptance test |
| 3 | T12 S0 测试 harness + `selfhost-smoke-{arch}` job |
| 4 | T20 S1 中型测试 + `selfhost-medium-{arch}` job |
| 5 | T23 S2 cargo 测试 + `selfhost-cargo-{arch}` job |
| 6 | T26 S3 自举测试、T27 S4 reproducibility |

**主写文件**：
- `tests/selfhost/`
- `.github/workflows/selfhost.yml`、`selfhost-nightly.yml`、`selfhost-weekly.yml`
- `scripts/run-selfhost-tests.sh`、`scripts/selfhost-smoke.sh`、…

**约束**：
- C 测试 musl 静态编译，跨架构通用
- 输出 `[TEST] <name> <PASS|FAIL>` 统一格式
- 单文件、独立 main、不依赖 framework

---

## 跨角色协作矩阵

| 接口 | 提供方 | 消费方 | 约定 |
|---|---|---|---|
| `de_thread()` 同步原语 | D1 (T1) | T11 futex PI / T6 ptrace | 公开在 `task/exit.rs` 或 `task/mod.rs` |
| `record_lock::release_for_process(pid)` | D3 (T2) | D1 do_exit 路径 | T2 PR 加 pub 导出，T1 PR 调用 |
| `ProcessData::rlimits` 字段 | D2 (T5) | D1 clone / D2 T9 setpriority | T5 PR 在 ProcessData 加字段 |
| `/proc/cpuinfo` 内容 | D2 (T8) | D4 测试 nproc | x86 含 `processor`+`model name`，riscv 含 `isa` |
| musl-cross 工具链 | rootfs (T10) | D4 测试编译 | musl-gcc-{arch} 静态版 |
| selfhost rootfs 路径 | D2 (T10) | D4 (T12+) CI | `tests/selfhost/rootfs-selfhost-<arch>.img` 或 GitHub release URL |

## 启动 / 调度规则

- 每个任务一次 `cursor-agent -p ...` 调用，独立 session。
- 同时启动数 ≤ 5（避免 token + worktree 数量爆）。
- subagent 异常（exit ≠ 0）：dispatcher 写日志 + 通知 Director。
- subagent 完成必须返回结构化 JSON summary（commit SHA / patch 文件列表 / PR URL / 自检表）。
- Director 解析 JSON 后写入 `PROCESS-LOG.md`。
