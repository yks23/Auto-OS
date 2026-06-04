# M6 Self-hosting 验收总结报告

日期：2026-05-16

## 目标

本阶段目标是验证 StarryOS 不只能够启动和运行简单用户程序，还能够在 QEMU RISC-V guest 内承载 Rust 工具链，并逐步推进到 guest 内编译 StarryOS kernel/lib 的 M6 self-hosting 路线。

## 仓库关系

- 上游目标仓库：`rcore-os/tgoskits`，最终 PR 目标是其 `main` 分支。
- 开发 fork：`yks23/tgoskits`，Auto-OS 中的 `tgoskits` submodule 指向该 fork。
- 实验仓库：`yks23/Auto-OS` 的 `dev` 分支，用于保存 Docker、QEMU、rootfs、复现脚本和实验记录。

因此，Auto-OS 是实验、复现和验收材料仓库；真正要提交给上游的内核/StarryOS 改动，需要在 `tgoskits` fork 中整理成可阅读、可 review 的小 PR。

## 已完成工作

### 1. Hello world 已通过

已经完成 StarryOS guest 内基础用户态程序验证，`hello world` 可以在当前实验链路中运行通过。这说明：

- QEMU RISC-V guest 可以正常启动。
- StarryOS 基础用户态执行链路可用。
- rootfs、init delegation、guest 脚本入口和日志回传机制可以工作。
- 后续 Rust/cargo 编译实验不是停留在启动阶段，而是在可运行 guest 环境上继续推进。

### 2. Guest selfbuild 环境已建立

已经完成一套可重复运行的 M6 selfbuild 实验环境：

- 使用 Docker 提供 host 侧可控环境。
- 使用 QEMU 启动 RISC-V StarryOS guest。
- 构建并维护 `.guest-runs/rootfs-selfbuild-riscv64.img`。
- 在 rootfs 中放入 Alpine Rust 工具链、cargo registry、rust-src 与 `tgoskits` workspace。
- 通过 guest init delegation 运行 `/opt/run-tests.sh`，让编译动作发生在 StarryOS guest 内。

### 3. StarryOS 编译实验已进入内核 crate 阶段

最新一轮 StarryOS 编译实验配置为：

```text
/tmp/m6-full-run10.log
M6_QEMU_SMP=1
M6_QEMU_MEM=5G
CARGO_BUILD_JOBS=1
RAYON_NUM_THREADS=1
phase=starry-kernel-lib
```

该轮实验确认已经进入 guest 内 StarryOS kernel/lib 编译链路，而不是 host 编译或简单 smoke test。日志中可以看到 Rust/cargo 在 guest 内运行，并推进到 `core`、`alloc`、`compiler_builtins` 以及 ArceOS/StarryOS kernel crate 编译阶段。

## StarryOS 编译速度

最新 StarryOS guest 编译实验持续约：

```text
18383 秒，约 5 小时 6 分钟
```

这个时间来自 host 侧 QEMU 运行统计日志，即从启动 guest、进入 Rust/cargo 编译，到本轮 StarryOS kernel/lib 编译实验结束的总耗时。

从实验观察看，当前速度主要受以下因素影响：

- QEMU TCG 是软件模拟，host 不能直接执行 guest RISC-V 指令。
- 当前为了稳定性使用单 vCPU：`M6_QEMU_SMP=1`。
- cargo/rustc 当前固定单 job：`CARGO_BUILD_JOBS=1`。
- guest 内 Rust 编译会产生大量小文件读写，压力集中在 rsext4/ext4 路径。
- 串口日志和 syscall stats 会带来额外 I/O 成本。

因此，当前 StarryOS guest 内编译速度属于“稳定优先”的基线配置，不是性能最优配置。它的意义是先证明链路能够长时间推进，再逐步打开并行和降日志优化。

## QEMU / vCPU 配置

当前 M6 默认采用：

```text
M6_QEMU_SMP=1
```

也就是单个 guest vCPU。这里的 vCPU 是 QEMU 暴露给 guest OS 的虚拟 CPU，guest 会把它看成一颗可以调度任务的 CPU。

当 `smp > 1` 时，实验脚本会使用：

```text
-accel tcg,thread=single
```

这是为了规避 QEMU RISC-V TCG 多线程模式下 LR/SC 原子语义不稳定的问题。当前先用单 vCPU 保证 Rust 编译正确性和复现稳定性，后续可以在确认内核同步路径稳定后，再评估多 vCPU 并行收益。

## 后续优化方向

### 1. 降低串口日志量

已经在 `tgoskits` 中准备了一个降日志补丁分支：

```text
codex/quiet-rsext4-m6-logs
```

该补丁将高频 rsext4 诊断从默认可见级别降级：

- `rsext4_mkfile stage=...` 从 `warn` 降到 `trace`。
- `journal is enabled but JBD2 state is not initialized...` 从 `error` 降到 `trace`。
- `dir block checksum mismatch...` 从 `error` 降到 `debug`。

下一轮实验可以显著减少串口刷屏，使日志更可读，也降低一部分 I/O 开销。

### 2. 分阶段打开并行

当前配置是：

```text
CARGO_BUILD_JOBS=1
RAYON_NUM_THREADS=1
```

后续可以在稳定性确认后逐步尝试：

- 保持 QEMU 单 vCPU，但减少日志，观察纯日志优化收益。
- 尝试 `CARGO_BUILD_JOBS=2`，观察 Rust 编译阶段是否有收益。
- 尝试 `M6_QEMU_SMP=2` 配合 `-accel tcg,thread=single`，观察 guest 调度和 I/O 是否更顺。
- 对 rootfs 镜像、rsext4 写入路径和 cargo target 目录做更细粒度 profiling。

### 3. 拆分上游 PR

当前 Auto-OS 的 `dev` 分支适合保存完整实验过程；上游 PR 不应该直接提交整个实验仓库。建议后续在 `tgoskits` fork 中按主题拆分：

- StarryOS/ArceOS 必要功能修复。
- rsext4 文件系统稳定性修复。
- M6 selfbuild 所需的脚本或文档。
- 降日志补丁。

这样每个 PR 都能独立解释动机、影响范围和验证方式，更适合提交到 `rcore-os/tgoskits:main`。

## 验收结论

当前已经完成从 `hello world` 到 StarryOS guest 内 Rust/cargo 编译实验的推进：

- 基础用户程序运行通过。
- QEMU RISC-V StarryOS guest 可稳定启动。
- guest rootfs、Rust 工具链、cargo registry、rust-src 和 selfbuild 脚本链路已建立。
- StarryOS kernel/lib 编译实验已经能在 guest 内长时间推进。
- 当前速度基线约为 5 小时量级，主要瓶颈来自 QEMU TCG 软件模拟、单 vCPU、单 cargo job、rsext4 小文件 I/O 和串口日志。

这说明 M6 self-hosting 路线已经从“能否启动和运行程序”推进到“如何更快、更稳定地在 StarryOS guest 内完成真实内核编译”的阶段。下一步工作应集中在降日志、分阶段并行和上游 PR 拆分整理。
