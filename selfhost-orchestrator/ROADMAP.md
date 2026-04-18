# StarryOS Self-Hosting 路线图（x86_64 + riscv64）

**总开发师**：cursor cloud agent（"Director"）  
**上游基线**：`https://github.com/rcore-os/tgoskits` 的 `dev` 分支  
**fork**：`https://github.com/yks23/tgoskits`，集成分支 `selfhost-dev`（基于 upstream `dev`）  
**工作模式**：4 个虚拟开发岗位（D1-D4） + 1 个总开发师，**所有开发岗位由 cursor-agent subagent 实例承担**，并发推进，每个 subagent 各自独立的 git worktree 与分支。  

---

## 1. 终态目标（Definition of Done）

在 guest 内（x86_64 与 riscv64 各一份），从源码出发：

| 阶段目标 | 描述 | 衡量 |
|---|---|---|
| **S0** | `cc hello.c -o hello && ./hello` | exit 0，stdout 含 hello |
| **S1** | `make` 编译并链接出 BusyBox 等价规模 C 项目 | 全部 link 成功 |
| **S2** | `cargo build --release` 出可在 guest 内执行的小型 Rust 程序 | exit 0 |
| **S3** | guest 内 `cargo xtask starry build --arch <arch>` 重新编出 StarryOS kernel ELF | ELF 可以被 host QEMU 启动到 BusyBox shell |
| **S4** | guest 内 build 出的 kernel ELF 与 host build 的字节相同（再现性） | sha256 匹配 |

**两架构都必须达到 S3，S4 是 stretch goal。**

## 2. 关键路径图（Critical Path）

```
            ┌───────────────────────────────────┐
            │ Phase 0  基础设施（必须先做）       │
            │  - GitHub App 写权限                │
            │  - selfhost-dev 集成分支             │
            │  - dispatcher worktree 隔离          │
            └────────────────┬──────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
 ┌────────────┐      ┌────────────┐      ┌────────────┐
 │ Phase 1     │      │ Phase 1     │      │ Phase 1     │
 │  D1-内核组  │      │  D2-资源组  │      │  D3-FS/IO组 │
 │  T1 execve  │      │  T5 rlimit  │      │  T2 locks   │
 │             │      │             │      │  T4 mount   │
 └─────┬──────┘      └─────┬──────┘      └─────┬──────┘
       │                    │                    │
       └────────────────────┼────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
 ┌────────────┐     ┌────────────┐     ┌────────────┐
 │ Phase 2     │     │ Phase 2     │     │ Phase 2     │
 │  D1 ptrace  │     │  D2 工具链  │     │  D3 IPv6     │
 │             │     │  rootfs     │     │  T3          │
 └─────┬──────┘     └─────┬──────┘     └─────┬──────┘
       │                   │                   │
       └─────────────┬─────┴───────────────────┘
                     ▼
            ┌────────────────────────────┐
            │ Phase 3  S0 自我编译验证      │
            │   guest 内编 hello.c 通过    │
            └─────────────┬──────────────┘
                          │
              ┌───────────┼───────────┐
              ▼                       ▼
       ┌───────────┐           ┌────────────┐
       │ Phase 4    │           │ Phase 4     │
       │  D1 vDSO   │           │ D4 CI 闸门  │
       │  prctl     │           │ 测试矩阵    │
       │  D3 9p     │           │             │
       └─────┬─────┘           └──────┬──────┘
             │                         │
             └────────────┬────────────┘
                          ▼
            ┌────────────────────────────┐
            │ Phase 5  S1/S2 中型自我编译   │
            │   guest 内 BusyBox + cargo  │
            └─────────────┬──────────────┘
                          ▼
            ┌────────────────────────────┐
            │ Phase 6  S3/S4 完全自我编译   │
            │   guest 内编 starry kernel  │
            └────────────────────────────┘
```

## 3. 阶段详细计划

### Phase 0：基础设施（**所有人都被它阻塞**）

负责：总开发师 + 你（人，需要在 GitHub Web 端授权）。

| 子项 | 状态 | 负责 | 验收 |
|---|---|---|---|
| `tgoskits` remote 改成 `origin=yks23/tgoskits`、`upstream=rcore-os/tgoskits` | ✅ | Director | `git remote -v` 验证 |
| Cursor GitHub App 装到 `yks23/tgoskits` 仓库（**人，必须做**） | ⛔ 阻塞 | 你 | 在 https://github.com/apps/cursor-agent/installations/new 中授权该仓库 |
| `selfhost-dev` 集成分支（基于 `upstream/dev`） | ⛔ 等权限 | Director | `git push -u origin selfhost-dev` 成功 |
| dispatcher 给每个 subagent 独立 git worktree | 🔄 进行中 | Director | 5 个 worktree 互不干扰 |
| 验收测试集骨架（`test-suit/selfhost/`） | 未开始 | D4 | 见 TEST-MATRIX.md |

**Phase 0 出口标准**：5 个 subagent 任意 push 到 `yks23/tgoskits` 的对应分支都成功。

---

### Phase 1：基线修复（5 任务并发，~1 周等价工作量）

每条独立 PR、独立分支，**互相不会冲突的代码区域**。

| 任务 | Owner | 改动文件 | 估算行数 | 风险 |
|---|---|---|---|---|
| **T1** 多线程 execve | D1 | `kernel/src/syscall/task/execve.rs`、`mod.rs` (+execveat) | 100-200 | 中（需要和 do_exit 同步） |
| **T2** flock + fcntl 记录锁 | D3 | `kernel/src/file/{flock,record_lock}.rs`、`fd_ops.rs` | 500-700 | 中（fd close 路径） |
| **T3** AF_INET6 socket | D3 | `kernel/src/syscall/net/{socket,addr,opt}.rs` | 100-300 | 低（v4-mapped fallback） |
| **T4** mount ext4/9p | D3 | `kernel/src/syscall/fs/mount.rs`、`Cargo.toml` | 200-2000 | 高（9p 是大件） |
| **T5** 资源限制 | D2 | `kernel/src/config/*.rs`、`syscall/task/rlimit.rs`、`Makefile` | 100-200 | 低 |

**Phase 1 出口标准**：
- 5 个 PR 全部合入 `yks23/tgoskits` 的 `selfhost-dev` 集成分支。
- `make ARCH=riscv64 build && make ARCH=x86_64 build` 双架构 ✅。
- `make ARCH=riscv64 ci-test && make ARCH=x86_64 ci-test` 双架构 ✅。
- 每个任务的 acceptance test C 用例都通过（见 TEST-MATRIX.md Phase 1 部分）。

---

### Phase 2：补齐工具链 & 关键 syscall

| 任务 | Owner | 描述 | 估算 |
|---|---|---|---|
| **T6** ptrace 子集 | D1 | TRACEME/ATTACH/DETACH/CONT/PEEKDATA/POKEDATA/GETREGS/SETREGS/SINGLESTEP/SYSCALL | 1500-2500 行，架构相关 |
| **T7** prctl 完善 | D1 | PDEATHSIG/DUMPABLE/NO_NEW_PRIVS/KEEPCAPS/TID_ADDRESS/CHILD_SUBREAPER | 200-300 行 |
| **T8** procfs 关键节点 | D2 | self/exe、cpuinfo、meminfo、sys/kernel/random/{boot_id,uuid} | 300-500 行 |
| **T9** 缺失 syscall | D2 | execveat / waitid / openat2 / personality / setpriority(全PID) / getresuid | 400-600 行 |
| **T10** rootfs-selfhost 镜像 | D2 | 基于 Alpine musl 打包 gcc/binutils/make/rust，每架构一份 | 镜像构建脚本 |
| **T11** futex PI（可选） | D1 | LOCK_PI/UNLOCK_PI/TRYLOCK_PI | 300-500 行 |

**Phase 2 出口标准**：
- 上述任务每条独立 PR 合入 `selfhost-dev`。
- `rootfs-selfhost-{x86_64,riscv64}.img.xz` 在 GitHub releases 发布。
- `strace /bin/ls` 在 guest 内能正常输出。
- guest 内 `cat /proc/cpuinfo /proc/meminfo` 输出合理。

---

### Phase 3：S0 自我编译冒烟（小里程碑）

| 任务 | Owner | 描述 |
|---|---|---|
| **T12** S0 测试 harness | D4 | guest 内编 hello.c → 运行；CI workflow 跑 |
| **T13** x86_64 vDSO 最小集 | D1 | `__vdso_clock_gettime`、`__vdso_getcpu`，glibc 不爆 |
| **T14** AddrSpace 锁优化 | D1 | Mutex → RwLock，并发 page fault 不串行 |

**Phase 3 出口标准**：guest 内 `gcc hello.c -o hello && ./hello` 双架构 ✅。CI 中加 `selfhost-smoke-{arch}` job。

---

### Phase 4：补齐稳定性 + CI 闸门

| 任务 | Owner | 描述 |
|---|---|---|
| **T15** 信号 per-thread | D1 | `BLOCK_NEXT_SIGNAL_CHECK` → Thread 字段 |
| **T16** mremap 真实 remap | D1 | 替换 mmap+memcpy 实现 |
| **T17** madvise 真实生效 | D1 | DONTNEED/FREE/REMOVE |
| **T18** virtio-9p 完整版 | D3 | 实现 9p2000.L 协议；host 源码直通 |
| **T19** sysfs cpu 节点 | D2 | nproc 用 |
| **T20** S1 中型测试 | D4 | guest 内编 BusyBox 全套 |

**Phase 4 出口标准**：guest 内能完整编出 BusyBox 并执行。

---

### Phase 5：S2 cargo 自我编译

| 任务 | Owner | 描述 |
|---|---|---|
| **T21** rootfs 加 rust 工具链 | D2 | rustc + cargo musl 静态版 |
| **T22** AF_INET6 完整栈 | D3 | smoltcp v6，不再 fallback；保证 cargo 真能下 crate（或离线 mirror） |
| **T23** S2 cargo 测试 | D4 | guest 内 `cargo new && cargo build` |

**Phase 5 出口标准**：guest 内 `cargo build` 一个 100 行 Rust 程序双架构 ✅。

---

### Phase 6：S3/S4 自举

| 任务 | Owner | 描述 |
|---|---|---|
| **T24** xtask guest 兼容 | D2 | `cargo xtask starry build` 在 guest 内不假设 host 路径 |
| **T25** 调大 swap / disk | D2 | guest 内编 LLVM/rustc 的内存峰值需要 ≥ 8 GiB |
| **T26** S3 测试 | D4 | guest 内 build 出的 kernel ELF 用 host QEMU 启动到 BusyBox |
| **T27** S4 reproducibility | D4 | host build 与 guest build 字节对比 |

**Phase 6 出口标准**：guest 内重建 kernel ELF，能被 host QEMU 启动到 BusyBox shell。

---

## 4. 4 人小组分工概览

| 角色 | 简称 | 阶段 1 主任务 | 阶段 2 主任务 | 详情 |
|---|---|---|---|---|
| Kernel Core | **D1** | T1 execve | T6 ptrace、T7 prctl、T11 futex | 见 ROLES.md |
| Resource & Build | **D2** | T5 rlimit | T8 procfs、T9 syscall、T10 rootfs | 见 ROLES.md |
| FS & Net | **D3** | T2 locks、T3 IPv6、T4 mount | T18 9p | 见 ROLES.md |
| Test & CI | **D4** | （等 Phase 1 PR）准备测试 harness | T12/T20/T23/T26/T27 测试矩阵 + CI | 见 ROLES.md |

## 5. 协作规则（多人并发开发的硬约束）

### 5.1 分支模型

```
upstream/dev   ←  PR  ←  yks23/tgoskits/selfhost-dev   ←  PR  ←  cursor/selfhost-<task>-7c9d
       (rcore-os/tgoskits)         (集成分支)                          (子任务分支)
```

- **每个子任务（T1-T27）一个独立分支**，命名 `cursor/selfhost-<slug>-7c9d`。
- **每个子任务一个独立 PR**，目标先合入 `yks23/tgoskits` 的 `selfhost-dev`。
- 每周一次（或每个阶段结束），由 Director 把 `selfhost-dev` 整个 rebase/merge 后开 PR 到 `rcore-os/tgoskits` 的 `dev`。
- **任何任务都基于最新的 `upstream/dev`**，不基于 `selfhost-dev`，避免子任务互相依赖。

### 5.2 文件级隔离

每个 subagent **必须在独立的 git worktree** 中工作，路径由 dispatcher 自动准备：

```
/workspace/tgoskits                       # Director 主 worktree（dev）
/workspace/.worktrees/T1-execve-mt        # D1 在这里干活
/workspace/.worktrees/T2-file-locks       # D3 在这里干活
...
```

worktree 由 dispatcher 启动 subagent 前 `git worktree add` 创建，结束后 `git worktree remove`。

### 5.3 文件冲突预防

按"文件主权"分配，5 个 Phase 1 任务的写文件区不重叠（**经过预先核对**）：

| 任务 | 主写文件 |
|---|---|
| T1 | `kernel/src/syscall/task/execve.rs`、`kernel/src/syscall/mod.rs`（仅加 `execveat` arm） |
| T2 | 新增 `kernel/src/file/{flock,record_lock}.rs`，改 `kernel/src/syscall/fs/fd_ops.rs`、`kernel/src/file/mod.rs` |
| T3 | `kernel/src/syscall/net/{socket,addr,opt}.rs` |
| T4 | `kernel/src/syscall/fs/mount.rs` |
| T5 | `kernel/src/config/{x86_64,riscv64,aarch64,loongarch64}.rs`、`Makefile`、`make/qemu.mk`、新增 `kernel/src/syscall/task/rlimit.rs` |

⚠️ **唯一可能冲突点**：T1 与 T2 都会动 `kernel/src/syscall/mod.rs`（T1 加 execveat、T2 不会动）；T2 改 `kernel/src/file/mod.rs`（注册新模块）、T1 不动；这两条**无实际冲突**。

### 5.4 Commit 与 PR 约定

- **Conventional Commits**：`<type>(<scope>): <subject>`，例如 `feat(starry/syscall): real flock implementation`。
- 每条 commit 一个独立小改动，不批量。
- 每个 PR 有完整的 acceptance criteria 自检表（参见任务包模板）。
- PR 描述链回本路线图与对应任务包。
- PR 在所有 CI 通过、Director review 后，由 Director 合入。

### 5.5 同步与冲突处理

- **每天**（或每个 subagent 结束时）Director rebase `selfhost-dev` 上的最新 PR；冲突由相关 subagent 在自己分支 rebase 解决。
- **不允许**任何 subagent 直接 push 到 `selfhost-dev` 或 `dev`；只能 PR。
- **依赖关系**：T6 (ptrace) 依赖 T7 (prctl) 中的 `PR_SET_PTRACER`，但 prctl 可以先合入；并发开发但 review 顺序 T7→T6。
- **共享 PR**：T22 (smoltcp v6) 可能要改 axnet 子树，需要先和上游 axnet 维护者沟通；这种"跨项目"任务由 Director 决策是否拆。

### 5.6 测试纪律

- 每个 PR **必须**附带至少 1 个 C/Rust 测试用例，放在 `tgoskits/test-suit/starryos/selfhost/`。
- 测试用例命名 `test_<feature>_<aspect>.c`。
- 必须 musl 静态编译；输出统一 `[TEST] <name> PASS|FAIL` 格式。
- 见 TEST-MATRIX.md。

## 6. 时间预估（不按日历，按"任务点"）

| Phase | 任务点 | 关键路径长度 |
|---|---|---|
| Phase 0 | 4 项 | 1（取决于人授权） |
| Phase 1 | 5 项并发 | 1 任务点 |
| Phase 2 | 6 项，可分 2 批 | 2 任务点 |
| Phase 3 | 3 项，T13/T14 并发 | 1.5 任务点 |
| Phase 4 | 6 项，可分 2 批 | 2 任务点 |
| Phase 5 | 3 项，可分 2 批 | 1.5 任务点 |
| Phase 6 | 4 项 | 2 任务点 |

总计关键路径 ≈ **11 任务点**，并发度 4-5。

## 7. 风险登记册（Risk Register）

| 风险 | 影响 | 缓解 |
|---|---|---|
| Cursor App 没有 `yks23/tgoskits` 写权限 | Phase 0 阻塞，整个流程跑不动 | **你必须授权**（Phase 0 出口） |
| 并发 subagent 互相踩踏文件 | merge conflict 失控 | dispatcher worktree 隔离 + 5.3 文件主权 |
| API token 额度爆掉 | 任务卡到一半 | dispatcher 可 `--only` 单跑、串行 fallback |
| 9p 实现工作量超估 | T4/T18 阻塞自我编译 | 9p 列为 stretch；S0-S2 只用 ext4 第二块磁盘也能跑 |
| ptrace 改 trap 路径风险高 | T6 把内核搞崩 | T6 隔离在独立 PR，先在测试套验证再合入 |
| 子 agent 输出质量参差 | 修复后还是 broken | Director 每个 PR 强制 review；T12/T20/T23/T26 CI 闸门兜底 |

## 8. 文档索引

- `README.md` — orchestrator 总览
- `ROADMAP.md` ← 本文件
- `ROLES.md` — 4 个开发岗位的职责
- `TEST-MATRIX.md` — 验收测试用例矩阵
- `PROCESS-LOG.md` — 实时开发日志
- `tasks/T*.md` — 27 个任务包 prompt
