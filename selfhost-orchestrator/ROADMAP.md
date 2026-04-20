# StarryOS Self-Hosting 路线图（x86_64 + riscv64）

**总开发师**：Director（cursor cloud agent）  
**所有工作发生在**：`yks23/Auto-OS` 这一个仓库  
**对 tgoskits 的修改方式**：**patch 文件**，见 [`patches/README.md`](../patches/README.md)  
**上游 pin**：`tgoskits @ c7e88fb3`（由 `PIN.toml` 锁定）

## 0. 工作模式（重要！）

```
+--------------------------------------+
|  Auto-OS 仓（这个仓库，全部权限在内）   |
|                                       |
|  patches/         ← 真正的修改         |
|  scripts/         ← apply / build / test
|  tests/selfhost/  ← C 测试用例         |
|  PIN.toml         ← tgoskits base     |
|  tgoskits/        ← submodule, ro pin  |
|     ↑                                  |
|     └── 临时被 apply 出 patches 后用于 build/test
+--------------------------------------+
```

每个任务的产出是 `patches/Tn-slug/0001-*.patch …` 文件。CI 从干净 pin 出发 apply 所有 patch、跨架构 build、跑 ci-test。

子 agent 永远不需要 push tgoskits；只需要 push Auto-OS 仓的任务分支并开 PR。

## 1. 终态目标（Definition of Done）

| 里程碑 | 描述 | 衡量 |
|---|---|---|
| **M0** | apply→build 流水线在 CI 上跑通 | `selfhost / build (riscv64)` 与 `(x86_64)` 双 ✅ |
| **M1** | Phase 1 五个核心 PR 全部合入 | patches/T1-T5 都在 main，sanity-check 通过 |
| **M2** | guest 内 `gcc hello.c -o hello && ./hello` 双架构成功 | CI smoke-test job 通过 |
| **M3** | guest 内 `make` 编出 BusyBox 双架构成功 | CI medium-test job 通过 |
| **M4** | guest 内 `cargo build` 一个简单 Rust 程序 | CI s2-cargo job 通过 |
| **M5** | guest 内 `cargo xtask starry build` 重建 kernel ELF | host 用该 ELF 启动到 BusyBox shell |
| **M6** | host build 与 guest build 字节相同 | sha256 一致（stretch） |

**M0-M5 必须达成，M6 列为 stretch goal。**

## 2. 关键路径

```
                ┌───────────────────────────┐
                │ Phase 0  基础设施          │
                │  - patches workflow ✅     │
                │  - CI selfhost.yml         │
                │  - dispatcher worktree    │
                │  - tests/selfhost 骨架    │
                └────────────┬──────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
 ┌────────────┐      ┌────────────┐      ┌────────────┐
 │ Phase 1     │      │ Phase 1     │      │ Phase 1     │
 │  D1 内核组  │      │  D2 资源组  │      │  D3 FS/IO  │
 │  T1 execve  │      │  T5 rlimit  │      │  T2 locks   │
 │             │      │             │      │  T3 IPv6    │
 │             │      │             │      │  T4 mount   │
 └─────┬──────┘      └─────┬──────┘      └─────┬──────┘
       │                   │                    │
       └───────────────────┼────────────────────┘
                           │
                           ▼   ← M1 = Phase 1 结束
                ┌───────────────────────────┐
                │ Phase 2  补 syscall +     │
                │  rootfs 工具链镜像        │
                │ T6 ptrace, T7 prctl       │
                │ T8 procfs, T9 misc        │
                │ T10 rootfs-selfhost       │
                └────────────┬──────────────┘
                             │
                             ▼   ← M2 = S0 自我编译冒烟
                ┌───────────────────────────┐
                │ Phase 3  S0 验证           │
                │ T12 hello.c               │
                │ T13 x86 vDSO              │
                │ T14 AddrSpace 锁          │
                └────────────┬──────────────┘
                             │
                             ▼   ← M3 = S1 BusyBox
                ┌───────────────────────────┐
                │ Phase 4  稳定性 + S1       │
                │ T15-T20                    │
                └────────────┬──────────────┘
                             │
                             ▼   ← M4 = S2 cargo
                ┌───────────────────────────┐
                │ Phase 5  cargo            │
                │ T21-T23                    │
                └────────────┬──────────────┘
                             │
                             ▼   ← M5 / M6 = S3/S4 自举
                ┌───────────────────────────┐
                │ Phase 6  完全自举          │
                │ T24-T27                    │
                └───────────────────────────┘
```

## 3. Phase 详细计划与 Checkpoints

每个 Phase 有 **Entry Criteria**（开干前提）、**Exit Criteria**（达成什么算完）、**Checkpoint Tests**（怎么自动验证完成）。

---

### Phase 0：基础设施

**Entry Criteria**：cursor-agent CLI + CURSOR_API_KEY 就绪。

**任务**：

| ID | 任务 | Owner | 状态 |
|---|---|---|---|
| P0.1 | patches workflow（apply/extract/sanity-check） | D0 | ✅ 已完成 |
| P0.2 | `.github/workflows/selfhost.yml` CI | D0 | ✅ 已完成 |
| P0.3 | `tests/selfhost/` 骨架 + sanity 测试 | D0 | ✅ 已完成 |
| P0.4 | dispatcher worktree 隔离 + patch 提取集成 | D0 | 🔄 进行中 |
| P0.5 | 主仓 PR #1 描述切到新工作模式 | D0 | 待做 |

**Exit Criteria**：在 CI 上 `sanity` job 绿、`build (riscv64)` 与 `build (x86_64)` 都绿（即使 patches 为空）。

**Checkpoint Tests**（CP-0）：
1. `bash scripts/sanity-check.sh` 本地 ✅
2. PR 触发 GitHub Actions selfhost workflow，3 个 job 都绿 ✅

---

### Phase 1：基线修复（5 个任务并行）

**Entry Criteria**：CP-0 通过。

**任务**：

| ID | 任务 | Owner | 主写文件 | 估算 patch 行数 |
|---|---|---|---|---|
| T1 | 多线程 execve + execveat | D1 | `kernel/src/syscall/task/execve.rs`, `mod.rs` | 100-200 |
| T2 | flock + fcntl 记录锁 | D3 | `kernel/src/file/{flock,record_lock}.rs`, `fd_ops.rs` | 500-700 |
| T3 | AF_INET6 socket | D3 | `kernel/src/syscall/net/{socket,addr,opt}.rs` | 100-300 |
| T4 | mount ext4 + bind | D3 | `kernel/src/syscall/fs/mount.rs` | 200-400 |
| T5 | 资源限制 + Makefile | D2 | `kernel/src/config/*.rs`, `Makefile`, 新增 `rlimit.rs` | 100-200 |

**文件主权边界（核对过无重叠）**：见 §6。

**Exit Criteria**（每任务，由 PR review 强制）：
- `patches/Tn-slug/` 下至少 1 个 patch + META.toml + README.md
- `tests/selfhost/` 下至少 1 个测试文件
- CI `sanity` 与 `build` 双架构绿
- PR 描述含 acceptance criteria 自检表

**Checkpoint Tests**（CP-1，所有 T1-T5 合并后）：

```sh
# 在 main 分支上
scripts/sanity-check.sh                                 # 全部 patch 不冲突
scripts/build.sh ARCH=riscv64                           # build 通过
scripts/build.sh ARCH=x86_64                            # build 通过
scripts/build.sh ARCH=riscv64 TARGET=ci-test            # ci-test 通过
scripts/build.sh ARCH=x86_64 TARGET=ci-test             # ci-test 通过
```

每个 T 的具体 acceptance test 见 [TEST-MATRIX.md](./TEST-MATRIX.md)。

---

### Phase 2：补齐工具链 & 关键 syscall

**Entry Criteria**：CP-1 通过。

**任务**：

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T6 | ptrace 子集 | D1 | 1500-2500 行 |
| T7 | prctl 完善（PDEATHSIG/DUMPABLE/NO_NEW_PRIVS/TID_ADDRESS/CHILD_SUBREAPER） | D1 | 200-300 |
| T8 | procfs 关键节点（self/exe, cpuinfo, meminfo, random/uuid） | D2 | 300-500 |
| T9 | 缺失 syscall（waitid, openat2, personality, setpriority(全PID), getresuid） | D2 | 400-600 |
| T10 | rootfs-selfhost 镜像构建脚本（基于 Alpine musl） | D2 | 镜像构建脚本 + GitHub release |
| T11 | （可选）futex PI | D1 | 300-500 |

**Exit Criteria**：
- `patches/T6..T10` 全部进 main
- `rootfs-selfhost-{x86_64,riscv64}.img.xz` 在 GitHub Releases 发布
- CI 加 job：`selfhost-toolchain-image-{arch}` 验证镜像里有 gcc/ld/make

**Checkpoint Tests**（CP-2）：
- `strace /bin/ls` 输出含 execve/openat/exit_group
- `cat /proc/cpuinfo`、`/proc/meminfo` 输出合理
- `wget <release-url>/rootfs-selfhost-x86_64.img.xz` 下载，解压挂载后 `ls /opt/toolchain/bin` 看到 gcc

---

### Phase 3：S0 自我编译冒烟

**Entry Criteria**：CP-2 通过 + rootfs-selfhost 镜像可用。

**任务**：

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T12 | S0 测试 harness（guest 内编 hello.c） | D4 | CI workflow + scripts/selfhost-smoke.sh |
| T13 | x86_64 vDSO 最小集（clock_gettime, getcpu） | D1 | 600-800 行（含汇编） |
| T14 | AddrSpace Mutex → RwLock | D1 | 200-400 行 |

**Exit Criteria**：CI 新 job `selfhost-smoke-{arch}` 双架构绿。

**Checkpoint Tests**（CP-3 = M2）：
```sh
# guest 内（CI 自动跑）
mount /dev/vdb /opt/toolchain
export PATH=/opt/toolchain/bin:$PATH
cat > /tmp/hello.c << 'EOF'
#include <stdio.h>
int main(){ puts("self-host hello"); return 0; }
EOF
gcc -static /tmp/hello.c -o /tmp/hello
/tmp/hello       # 期望: self-host hello
echo $?          # 期望: 0
```

---

### Phase 4：稳定性 + S1 BusyBox

**Entry Criteria**：CP-3 通过。

**任务**：

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T15 | 信号 per-thread skip-flag | D1 | 50-100 |
| T16 | mremap 真实页表 remap | D1 | 300-500 |
| T17 | madvise 真实生效（DONTNEED/FREE/REMOVE） | D1 | 200-300 |
| T18 | virtio-9p 完整版（host 源码直通） | D3 | 1500-2500 |
| T19 | sysfs cpu 节点 | D2 | 100-200 |
| T20 | S1 中型测试（guest 内编 BusyBox） | D4 | CI workflow + 镜像内放 BusyBox 源 |

**Exit Criteria**：CI 新 job `selfhost-medium-{arch}` 通过。

**Checkpoint Tests**（CP-4 = M3）：
```sh
guest$ tar xf /opt/sources/busybox-1.36.tar.gz -C /tmp
guest$ cd /tmp/busybox-1.36 && make defconfig && make -j$(nproc)
guest$ ls -lh busybox    # 期望: 静态 ELF, ~1MB
```

---

### Phase 5：S2 cargo

**Entry Criteria**：CP-4 通过 + rust 工具链已打包到 selfhost 镜像。

**任务**：

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T21 | rootfs 加 rust 工具链（musl 静态 rustc/cargo） | D2 | 镜像构建脚本扩展 |
| T22 | AF_INET6 完整栈（smoltcp v6） | D3 | 800-1500 |
| T23 | S2 cargo 测试 | D4 | CI workflow |

**Exit Criteria**：CI 新 job `selfhost-cargo-{arch}` 通过。

**Checkpoint Tests**（CP-5 = M4）：
```sh
guest$ rustc --version
guest$ cargo new /tmp/foo && cd /tmp/foo
guest$ cargo build --release
guest$ ./target/release/foo    # 期望: Hello, world!
```

---

### Phase 6：S3/S4 完全自举

**Entry Criteria**：CP-5 通过。

**任务**：

| ID | 任务 | Owner | 估算 |
|---|---|---|---|
| T24 | xtask guest 兼容（不假设 host 路径） | D2 | 100-300 |
| T25 | guest 大磁盘 + swap | D2 | QEMU 配置 + 镜像 + swapon 实现 |
| T26 | S3 测试（guest 编出 kernel ELF，host 用 QEMU 启动） | D4 | CI workflow |
| T27 | S4 reproducibility（guest sha256 == host sha256） | D4 | SOURCE_DATE_EPOCH + 固定 seed |

**Exit Criteria**：CI `selfhost-bootstrap-{arch}` 周 build 通过。

**Checkpoint Tests**（CP-6 = M5/M6）：
```sh
# host 上记录基线
host$ scripts/build.sh ARCH=x86_64
host$ HOST_SHA=$(sha256sum tgoskits/os/StarryOS/target/.../starryos.elf)

# guest 内重建
guest$ git clone https://github.com/yks23/Auto-OS
guest$ cd Auto-OS && scripts/apply-patches.sh --reset
guest$ scripts/build.sh ARCH=x86_64
guest$ scp ... guest-built.elf host:
host$ qemu-system-x86_64 -kernel guest-built.elf ...   # 启动到 BusyBox shell == M5

# 可选 M6
host$ sha256sum guest-built.elf == HOST_SHA
```

## 4. 4 人小组分工总览

| 角色 | Phase 1 主任务 | Phase 2-6 主任务 |
|---|---|---|
| **D1 Kernel Core** | T1 execve | T6 ptrace, T7 prctl, T11 futex, T13 vDSO, T14 RwLock, T15 信号, T16 mremap, T17 madvise |
| **D2 Resource & Build** | T5 rlimit | T8 procfs, T9 misc syscall, T10 rootfs, T19 sysfs, T21 rust 工具链, T24 xtask, T25 大磁盘 |
| **D3 FS & Net** | T2 locks, T3 IPv6, T4 mount | T18 9p, T22 v6 完整栈 |
| **D4 Test & CI** | （等 T1-T5 PR）准备 acceptance test | T12 S0, T20 S1, T23 S2, T26 S3, T27 S4，所有 CI workflow 维护 |

## 5. 协作硬约束（多人并发开发）

### 5.1 分支与 PR 模型（Auto-OS 仓内全闭环）

```
main                                 ← Director merge here
  ↑ PR
cursor/selfhost-T1-execve-mt-7c9d   ← D1 工作分支（Auto-OS 仓）
cursor/selfhost-T2-file-locks-7c9d  ← D3
cursor/selfhost-T3-ipv6-7c9d        ← D3
cursor/selfhost-T4-mount-fs-7c9d    ← D3
cursor/selfhost-T5-rlimit-7c9d      ← D2
```

每个任务一个分支、一个 PR、一个 `patches/Tn-slug/` 子目录。

### 5.2 worktree 隔离

每个 subagent 跑在 `/workspace/.worktrees/Tn-slug/` 独立 worktree（包含 Auto-OS 完整副本，自带子模块）。互不干扰。

### 5.3 文件主权（Phase 1 已核对）

每个 Phase 1 任务的写文件区无重叠：

| 任务 | tgoskits 内主写 | Auto-OS 内主写 |
|---|---|---|
| T1 | `kernel/src/syscall/task/execve.rs`、`syscall/mod.rs`（仅加 execveat arm） | `patches/T1-execve-mt/`、`tests/selfhost/test_execve_*.c` |
| T2 | 新增 `kernel/src/file/{flock,record_lock}.rs`、`fd_ops.rs`、`file/mod.rs` | `patches/T2-file-locks/`、`tests/selfhost/test_flock_*.c`、`test_fcntl_*.c` |
| T3 | `kernel/src/syscall/net/{socket,addr,opt}.rs` | `patches/T3-ipv6/`、`tests/selfhost/test_ipv6_*.c` |
| T4 | `kernel/src/syscall/fs/mount.rs` | `patches/T4-mount-fs/`、`tests/selfhost/test_mount_*.{c,sh}` |
| T5 | `kernel/src/config/*.rs`、`Makefile`、`make/qemu.mk`、新增 `kernel/src/syscall/task/rlimit.rs` | `patches/T5-rlimit/`、`tests/selfhost/test_rlimit_*.c` |

唯一可能交叉点：T1 与 T5 都改 `kernel/src/syscall/task/mod.rs`（加新子模块声明）。Director 在合并时手动解决（一行 `mod xxx;` 加在末尾）。

### 5.4 Commit 与 PR 约定

- **Conventional Commits**：`feat(starry/syscall): real flock implementation` 等。
- 每个 commit 一个独立改动，**不批量**。
- patches 提取后 Auto-OS 仓的 commit 用 `feat(patches/Tn): <description>` 格式。
- PR 描述必须含 acceptance criteria 自检表（每条 ✅/⚠️/❌/🚧 + 简短说明）。
- PR 必须 link 到对应 `selfhost-orchestrator/tasks/Tn-*.md`。

### 5.5 同步与冲突处理

- 每个任务独立基于 `PIN_COMMIT`，不互相依赖。
- 如果 sanity-check 报告 patches 之间冲突，Director 协调后冲突方在自己分支解决并重新 extract。
- PIN 升级独立 PR（`chore(pin): bump tgoskits to <sha>`），可能要求所有未合并的任务 rebase。

### 5.6 测试纪律

- 每 PR ≥ 1 个 C/Sh 测试用例。
- 测试输出统一 `[TEST] <name> PASS|FAIL` 格式。
- CI 用正则解析。

## 6. 风险登记册

| 风险 | 概率 | 影响 | 缓解 |
|---|---|---|---|
| patch 之间冲突 | 中 | sanity-check fail | §5.3 文件主权 + sanity-check 强制 |
| PIN 升级时 patch 全 rebase 失败 | 中 | 一次性返工 | PIN 升级走独立 PR，逐个验 |
| CI build 时间过长 | 中 | feedback 慢 | 缓存 musl toolchain + rootfs |
| 9p 实现工作量超估 | 高 | T18 阻塞 | M3 用第二块 ext4 镜像也能跑，9p 列 stretch |
| ptrace 改 trap 路径搞崩 | 中 | T6 阻塞 | T6 独立 PR，CI ci-test 兜底 |
| token 额度不够 | 低 | dispatcher fan-out 部分失败 | dispatcher 支持 `--only` 串行 fallback |
| subagent 输出质量参差 | 中 | 修复不全 | Director review + CI ci-test 强制 |
| upstream 大 rebase 同期发生 | 低 | PIN 升级密集 | 频率 ≤ 1 次/周 |

## 7. 文档索引

- `README.md` — orchestrator 入口
- `ROADMAP.md` ← 本文件
- `ROLES.md` — 4 个开发岗位
- `TEST-MATRIX.md` — 验收测试矩阵
- `PROCESS-LOG.md` — 实时开发日志
- `tasks/T*.md` — 任务包 prompt
- `../patches/README.md` — patches 工作流详解
- `../scripts/*.sh` — 工具脚本
- `../PIN.toml` — tgoskits base commit
