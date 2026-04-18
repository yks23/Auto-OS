# 角色与岗位（Roles）

每个角色由一个 cursor-agent subagent 实例承担，dispatcher 派发时给它对应的任务包 prompt。多个任务可以串行交给同一个角色实例（保留 session 上下文），也可以每任务一个新 session（推荐，避免 token 爆掉）。

## D0：Director（总开发师）

**当前 owner**：cursor cloud agent（即本会话）

**职责**：
1. 维护 `ROADMAP.md`、`ROLES.md`、`TEST-MATRIX.md`、`PROCESS-LOG.md`。
2. 编写 / 维护任务包（`tasks/T*.md`）。
3. 维护 dispatcher（`dispatcher.py`），管理 worktree、log、session id。
4. Review 所有子 agent 的 PR，决定是否合入 `selfhost-dev` 集成分支。
5. 周期性把 `selfhost-dev` rebase 到 `upstream/dev`，开 PR 到 `rcore-os/tgoskits`。
6. 对外汇报进度，对内做技术决策（方案选型、跨任务依赖）。

**工具**：
- `cursor-agent` CLI（fan-out subagent）
- `gh` CLI（read-only，看 PR/CI 状态）
- `ManagePullRequest` MCP（开/更 PR）
- `git worktree`

---

## D1：Kernel Core 工程师

**当前 owner**：cursor-agent subagent（按需启动）

**领域**：syscall 入口、task/thread、信号、内存、ptrace、futex、TLS。

**Phase 1 主任务**：
- T1 多线程 execve 真实修复（含补 execveat）

**Phase 2 主任务**：
- T6 ptrace 子集
- T7 prctl 完善
- T11 futex PI（可选）

**Phase 3 主任务**：
- T13 x86_64 vDSO 最小集
- T14 AddrSpace 锁优化（Mutex → RwLock）

**Phase 4 主任务**：
- T15 信号 per-thread
- T16 mremap 真实 remap
- T17 madvise 真实生效

**主写文件**：
- `kernel/src/syscall/task/`（execve、ptrace、clone、wait、schedule、thread）
- `kernel/src/syscall/sync/futex.rs`
- `kernel/src/task/{signal,user,mod}.rs`
- `kernel/src/syscall/mm/{mmap,mprotect,mremap}.rs`
- `kernel/src/syscall/mod.rs`（仅加新 syscall arm）

**输入产物**：任务包 prompt（含 acceptance criteria + 边界陷阱 + 提交策略）。

**输出产物**：
1. 一个 `cursor/selfhost-<task>-7c9d` 分支
2. 若干 conventional commits
3. 一个 PR（目标 `yks23/tgoskits/selfhost-dev`）
4. 至少 1 个测试用例（`test-suit/starryos/selfhost/test_<task>.c`）
5. PR 描述中含 acceptance criteria 自检表

---

## D2：Resource & Build 工程师

**当前 owner**：cursor-agent subagent

**领域**：资源限制、配置常量、Makefile、xtask、procfs/sysfs、rootfs 镜像。

**Phase 1 主任务**：
- T5 用户栈 / QEMU 内存 / FD 上限 / prlimit64 真实生效

**Phase 2 主任务**：
- T8 procfs 关键节点（self/exe、cpuinfo、meminfo）
- T9 缺失 syscall（execveat、waitid、openat2、personality、setpriority、getresuid）
- T10 rootfs-selfhost 镜像构建

**Phase 4-6 主任务**：
- T19 sysfs cpu 节点
- T21 rootfs 加 rust 工具链
- T24 xtask guest 兼容
- T25 调大 swap / disk

**主写文件**：
- `kernel/src/config/*.rs`
- `kernel/src/pseudofs/{proc,sys}/`
- `kernel/src/syscall/task/{rlimit,thread}.rs`
- `Makefile`、`make/*.mk`、`xtask/`
- `scripts/build-selfhost-rootfs/`（新增）

**与 D1 的接口**：
- T9 中的 execveat 实际逻辑由 D1 的 T1 提供（D2 只挂 syscall arm）。
- T10 镜像中预装的 musl 头文件版本必须与 D1/D3 实现的 syscall 集匹配。

---

## D3：FS & Net 工程师

**当前 owner**：cursor-agent subagent

**领域**：VFS、文件锁、mount、网络栈、socket。

**Phase 1 主任务**：
- T2 flock + fcntl 记录锁
- T3 AF_INET6 socket（v4-mapped fallback）
- T4 mount 放开 ext4（+ virtio-9p stretch）

**Phase 4-5 主任务**：
- T18 virtio-9p 完整版
- T22 AF_INET6 完整栈

**主写文件**：
- `kernel/src/file/{flock,record_lock,fs,mod}.rs`
- `kernel/src/syscall/fs/{mount,fd_ops}.rs`
- `kernel/src/syscall/net/{socket,addr,opt}.rs`
- `components/`（virtio-9p 驱动，可能涉及）

**与 D1 的接口**：
- T2 中"进程退出释放该进程 record lock"需要在 D1 维护的 `do_exit` 路径调用。两人需要约定 hook 函数签名（推荐：`record_lock::release_for_process(pid)`）。

---

## D4：Test & CI 工程师

**当前 owner**：cursor-agent subagent

**领域**：测试用例、CI workflow、自我编译里程碑验证。

**Phase 1 主任务**：
- 准备 `test-suit/starryos/selfhost/` 骨架
- 为 T1-T5 各写至少 1 个测试用例（与各 owner 协作）

**Phase 3 主任务**：
- T12 S0 测试 harness（guest 内编 hello）
- 在 GitHub Actions 加 `selfhost-smoke-{arch}` job

**Phase 4-6 主任务**：
- T20 S1 中型测试（BusyBox）
- T23 S2 cargo 测试
- T26 S3 完全自举测试
- T27 S4 reproducibility 测试

**主写文件**：
- `tgoskits/os/StarryOS/test-suit/starryos/selfhost/`（新增）
- `tgoskits/.github/workflows/selfhost.yml`（新增）
- `tgoskits/scripts/selfhost-*.sh`（新增）

**约束**：
- 测试用例必须 musl 静态编译，可在两架构上跑。
- 输出统一 `[TEST] <name> <PASS|FAIL>` 格式，CI 用正则判断。
- 每个测试用例独立 main，单文件，方便快速增删。

---

## 跨角色协作矩阵

| 接口 | 提供方 | 消费方 | 约定 |
|---|---|---|---|
| `de_thread()` 同步原语 | D1 (T1) | T11 futex PI、T6 ptrace | 函数公开在 `task/exit.rs` 或 `task/mod.rs` |
| `record_lock::release_for_process(pid)` | D3 (T2) | D1 do_exit 路径 | T2 PR 加导出，T1 PR 调用 |
| 资源限制存储位置 | D2 (T5) | D1 clone/T9 setpriority | `ProcessData::rlimits` 字段 |
| `/proc/cpuinfo` 内容 | D2 (T8) | D4 测试 nproc | 至少含 `processor` / `model name`（x86）/`isa`（riscv）行 |
| 测试用例编译器 | rootfs (T10) | D4 测试 | musl-gcc-{arch} 静态版 |
| selfhost rootfs 路径 | D2 (T10) | D4 (T12+) CI | `tgoskits/test-suit/selfhost/rootfs-selfhost-<arch>.img` |
| guest 内 cargo 行为 | D2 (T24) + D3 (T22) | D4 (T23) cargo 测试 | guest 能 `cargo build` 一个 100 行项目 |

## 启动 / 调度规则

- 每个任务包对应一次 `cursor-agent -p ...` 调用，**独立 session**，不 resume。
- 同时启动的 subagent 数量不超过 5（避免 token 爆 + worktree 数量爆）。
- subagent 异常（exit ≠ 0）时，dispatcher 把日志路径报告给 Director；Director 决定 retry 或重写 prompt。
- subagent 完成后必须返回结构化 summary（commit SHA / PR URL / 自检表），dispatcher 解析后写入 `PROCESS-LOG.md`。
