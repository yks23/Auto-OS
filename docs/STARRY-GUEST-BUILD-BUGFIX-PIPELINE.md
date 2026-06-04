# Starry 访客编译压测：缺陷与修补流水线

本文档归纳在 QEMU 内访客编译（含 M6 自编译、单 crate 压测）过程中暴露的内核与用户态问题、对应代码位置，以及仓库内建议的验证顺序。叙述以当前仓库实存文件为准。

## 一、压测中暴露的典型问题

### 1.1 Futex `WaitQueue` 与 `SpinNoIrq` 的睡眠边界

`WaitQueue` 内部用 `SpinNoIrq` 保护等待队列。若在关本地中断、持自旋锁期间执行可能阻塞或触发「可睡眠」路径的闭包（例如在条件判断里再拿 `ax_sync::Mutex`、或同步 `wake` 导致立即切换到持 `Mutex` 的 waiter），会与 `ax_task` 的 `might_sleep` / 原子上下文假设冲突，表现为内核 panic。

设计上要求：`condition` 不得在持队列锁时求值；`Waker::wake_by_ref` 须在释放锁之后批量调用，避免在 IRQ-off 临界区内间接进入可睡眠上下文。

### 1.2 `flock` / `record_lock` 全局表：自旋锁与阻塞锁混用

若 inode 级全局表用 `SpinNoIrq` 包裹，而 `flock` / `setlk` 等路径在 `WaitQueue::wait_if` 中又需要可阻塞的 `Mutex`，容易形成「在自旋临界区内睡眠」的嵌套，与 1.1 同类。压测下文件锁与 futex 交织时更易触发。

### 1.3 `exit_robust_list` 对用户指针的误用

`robust_list_head` 来自用户地址空间。若在内核侧把 `head` 当普通内核指针解引用（例如直接与 `entry` 比较链表终止条件），会在未通过 `vm_read` 校验前访问无效映射。另需处理 `entry` 为空的非法链表形态。

### 1.4 访客栈与 rustc 调试信息压力

musl 上 `cargo` / `rustc` 通过 pthread 创建工作线程；若默认线程栈过小，叠加栈保护（`-fstack-protector`），易出现「stack smashing detected」类错误。访客单 crate 脚本若默认携带完整 debuginfo，会显著加大 rustc 工作线程栈占用，与上述问题叠加。

### 1.5 macOS 等宿主上的交叉 objcopy

PATH 中可能出现仅适用于 Linux 的 `riscv64-linux-musl-objcopy`（例如在 Docker 或挂载卷场景下残留），在 macOS 上表现为「cannot execute binary file」或错误架构。若脚本未探测可执行性就直接调用，RISC-V 内核扁平化步骤会失败。

---

## 二、具体修复（文件级索引）

以下路径均在仓库内可查；不展开大段代码，仅说明职责与修复要点。


| 主题                        | 路径                                                     | 要点                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Futex 等待队列                | `tgoskits/os/StarryOS/kernel/src/task/futex.rs`        | `WaitQueue::wait_if` 在首次睡眠后于锁外重算 `condition`；`wake` 先把待唤醒 `Waker` 收集到 `Vec`，释放 `SpinNoIrq` 后再 `wake_by_ref`。模块注释说明禁止在持锁时求值 `condition` 或唤醒。                                |
| Robust list 退出            | `tgoskits/os/StarryOS/kernel/src/task/ops.rs`          | `exit_robust_list`：用 `head.addr()` 与 `offset_of!(RobustListHead, list)` 计算用户侧链表尾指针，避免把 `head` 当内核指针；先 `head.vm_read()` 再遍历；`while` 循环中对 `entry.is_null()` 返回 `BadAddress`。 |
| BSD flock 全局表             | `tgoskits/os/StarryOS/kernel/src/file/flock.rs`        | `FLOCK_INODES` 使用 `ax_sync::Mutex<HashMap<…>>`（非 `SpinNoIrq`），注释说明为避免 `flock_inode` → `wait_if` 在关中断自旋内嵌套可睡眠 `Mutex`。                                                      |
| POSIX record lock 全局表     | `tgoskits/os/StarryOS/kernel/src/file/record_lock.rs`  | `RECORD_INODES` 同样为 `Mutex`，注释说明 `setlk` → `wait_if` 路径不得睡在 IRQ-off 自旋区内。                                                                                                  |
| 关闭 fd 时的锁顺序               | `tgoskits/os/StarryOS/kernel/src/syscall/fs/fd_ops.rs` | 注释约定在释放文件表相关锁之后再做 `flock` / `record_lock` 清理，避免持锁调用可能阻塞的锁模块。                                                                                                               |
| 访客 onecrate 环境与 RUSTFLAGS | `scripts/guest-onecrate-inner.sh`                      | `cargo` 模式默认追加 `-C debuginfo=0`（可通过 `GUEST_ONECRATE_RUSTFLAGS` 覆盖）；注释说明减轻 musl 下 rustc 线程栈与栈保护冲突；另设 `RUST_MIN_STACK` 等。                                                    |
| musl pthread 默认栈          | `tgoskits/os/arceos/ulib/axlibc/c/pthread.c`           | `pthread_attr_init` 将默认栈设为 8MiB 量级，注释说明 128KiB 对 musl 上 cargo/rustc 工作线程过小、易触发 stack smashing。                                                                             |
| QEMU 启动前内核扁平化             | `scripts/qemu-run-kernel.sh`                           | RISC-V 分支对 `riscv64-linux-musl-objcopy` 除 `command -v` 外执行 `--version` 探测，失败则回退 `rustc` sysroot 下 `llvm-objcopy` 等；避免 macOS 上误用不可执行的同名工具。                                  |


若未来某条在分支中尚未合并，以 `git grep` / 文件是否存在为准；本文不写「计划中」条目，上表均对应当前树内文件。

---

## 三、当前修补与验证流水线（建议顺序）

### 3.1 本地格式与规则

1. 安装并启用 lefthook（仓库根 `lefthook.yml`）：`pre-commit` 对匹配 `tgoskits/**/*.rs` 的变更在 `tgoskits` 根执行 `cargo fmt --all --check`。
2. 人工提交前在 `tgoskits` 目录执行 `cargo fmt`（或至少 `cargo fmt --all --check` 通过）。
3. Cursor 侧可选阅读 `.cursor/rules/tgoskits-starry-static.mdc`，其中写明与 CI 对齐的 fmt 要求及 `ci-starry-static.sh` 入口。

### 3.2 CI 级静态检查

在 Auto-OS 仓库根执行：

```bash
bash scripts/ci-starry-static.sh
```

`scripts/ci-starry-static.sh` 的 `--docker-inner` 路径中明确约定先 `cargo fmt --check`（对整个 `tgoskits` workspace），再生成 axplat 配置并执行 clippy / `cargo check`（目标 `riscv64gc-unknown-none-elf`，包 `starry-kernel`、`starryos` 等）。本地无 Docker 时可设 `CI_STARRY_SKIP_DOCKER=1` 占位跳过（规则文件中有说明）。

### 3.3 宿主快速编译（小面包）

在 `tgoskits` 下针对用户态/库组件做快速反馈（不启动 QEMU），例如：

```bash
cd tgoskits
cargo check -p ax-errno
# 或 cargo build -p ax-errno
```

包名定义见 `tgoskits/components/axerrno/Cargo.toml`。完整内核仍以 CI 脚本或 `cargo xtask` 工作流为准（见 `tgoskits/AGENTS.md`）。

在 **Linux 宿主**（需安装 `strace`）可用 `scripts/host-cargo-syscall-total.sh` 对同一 `cargo` 命令跑 `strace -f -c`，得到 `===HOST_CARGO_SYSCALL_TOTAL===` 与完整 `-c` 报告路径；该数字仅为**宿主 strace 解析**，与 QEMU 内 Starry 串口 `/proc/syscall_stats` 导出块不可混为一谈（见工作区规则 `starry-guest-syscall-real`）。

### 3.4 访客最小到完整验证

按成本与覆盖面递增：

1. `scripts/guest-onecrate-syscall-evidence.sh`：privileged Docker 内跑 QEMU + Starry，结合 `scripts/guest-onecrate-inner.sh` 做受控 `rustc` / `cargo check`，并依赖 `/proc/syscall_stats_reset` 等（脚本内会检查）。可通过 `GUEST_ONECRATE_MODE=rustc` 走最简路径（无 cargo registry）。长编译阶段可由 `GUEST_ONECRATE_SYSCALL_STATS_SEC` 控制周期性 `===ONECRATE_SYSCALL_STATS_*===` 串口块；可选 `GUEST_ONECRATE_STATS_HTTP=1` 启本机 `127.0.0.1:1378` 侧车读同一串口文件。默认开启 `GUEST_ONECRATE_DEVLOG_SEC=15`（cargo 时经 `logger` 写 `/dev/log`）与 `GUEST_ONECRATE_TAIL_HTTP=1`（QEMU 前起 `tail-http-serve.py`，默认 `http://127.0.0.1:13888/` 看串口 `results.txt`）；`GUEST_ONECRATE_TAIL_HTTP=0` 或 `GUEST_ONECRATE_DEVLOG_SEC=0` 可关闭。
2. `scripts/verify-sterile-phase1.sh`：强制真实 `docker build`（缺镜像时）并调用上述 onecrate 证据脚本，清理历史 `results.txt` 避免误判。
3. `scripts/demo-m6-lite.sh`：对 `demo-m6-selfbuild.sh` 的薄封装，默认子集、`smp=1`、较小内存与超时，适合资源受限或迭代调试。
4. `scripts/demo-m6-selfbuild.sh`：完整 M6 访客自编译 Starry 内核；日志与成功标记见脚本头部注释（如 `===M6-SELFBUILD-PASS===` / subset 标记）。

### 3.5 可选：串口 syscall 统计的 HTTP 侧车

以下文件存在于仓库中，用于在冒烟验证时从串口捕获 `SYSCALL_STATS` 块并在本机 HTTP 展示（默认关闭，避免 CI 占端口）：

- `scripts/verify-starry-guest-smoke.sh`：环境变量 `STARRY_SMOKE_STATS_HTTP`、`STARRY_SMOKE_STATS_PORT`（默认 1378）说明。
- `scripts/starry-smoke-syscall-http.py`：解析逻辑与端口默认值的实现。

启用方式以脚本内注释为准；若仅关心访客内真实计数，仍以内核 `/proc/syscall_stats` 与串口导出块为权威来源（见工作区规则 `starry-guest-syscall-real`）。

在宿主上可用 `scripts/tail-http-serve.py` 对本机日志做浏览器自动刷新 tail（默认 `127.0.0.1:13888`，勿将 `TAIL_HTTP_BIND=0.0.0.0` 用于不可信网络）。例如：

```bash
python3 scripts/tail-http-serve.py .guest-runs/onecrate-klog-XXX/results.txt 13888
```

---

## 四、小结

访客编译压测同时挤压内核同步原语（futex、文件锁、robust futex 清理）与用户态（musl 线程栈、rustc 调试信息、宿主工具链）。当前树内通过「自旋锁内不睡眠、不唤醒」的队列实现、`Mutex` 化的全局 inode 表、用户指针安全遍历、C 库默认栈与脚本侧 `RUSTFLAGS` 默认值、以及 QEMU 脚本对 objcopy 的可执行性探测，形成一条从 fmt、CI 静态检查、宿主小包检查到分级访客脚本的修补与回归路径。