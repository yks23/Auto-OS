# StarryOS 自举相关：核心实现与代码体量

本文汇总 **为达成 M1→M6 路线所编写/集成的代码与脚本**（数量级与主要落点），不重复叙述任务顺序（见 [`SELFHOST-ROADMAP-TASKS.md`](./SELFHOST-ROADMAP-TASKS.md)）。

---

## 1. 内核侧：patch 与集成规模

### 1.1 Phase 1–2 集成（代表性数字）

Phase 2 集成总结中曾记载（见 git 历史中 `docs/PHASE2-FINAL-RESULTS.md`）：

- **约 14 组 patch 方向**（T1、T2、T3、T4、T5、F-α、F-β、F-γ、T8、T9、T10、M1.5 hook 等组合），**30+ 个 patch 文件**，合入 **`tgoskits/os/StarryOS/kernel`** 及相关组件的改动量级约 **三千余行**（含冲突解决与 SKIP 项说明）。  
- 其中 **T6/T7** 等曾与 `execve.rs` 冲突，部分阶段为 **SKIP 待手工 merge**——以当前子模块实际 tree 为准。

### 1.2 M5 全链关键：F-ε（vfork / posix_spawn / execve 与地址空间）

`cargo → rustc → cc → ld` 依赖 **真 vfork**、**posix_spawn** 及 **execve 后 SATP / 地址空间** 与调度器状态一致。实现要点（摘要）见 **`docs/DEMO.md`「关键内核工程修复」**：

- `clone.rs`：`CLONE_VFORK` + 共享/分离 aspace 分支。  
- `task/mod.rs`、`task/ops.rs`：vfork 父进程唤醒、`do_exit` 协作。  
- `execve.rs`：**多引用 aspace** 时换空用户地址空间、刷 TLB、**同步 `ctx.satp`**。  
- `axtask`：暴露 `ctx_mut_raw` 供 execve 修正已调度任务的保存上下文。

具体 diff 位于仓库 **`patches/`** 下对应目录（如 `patches/F-eps/` 等），以子模块与 `scripts/apply-patches.sh` 流程为准。

---

## 2. 用户态 / 镜像 / 脚本（可直接 `wc` 的量级）

以下为 **当前仓库** 内与 **M5/M6 自举演示** 强相关、且以单文件为主的体量（行数随提交变化，**约数**即可）：

| 路径 | 约行数 | 作用 |
|------|--------|------|
| `tests/selfhost/build-selfhost-rootfs.sh` | ~160 | M5 **rust profile** rootfs（Alpine + rustc/cargo 等）。 |
| `tests/selfhost/build-selfbuild-rootfs.sh` | ~540 | M6 **selfbuild** 大镜像（Debian + Alpine musl rust、ccwrap、`GUESTSH`、宿主 `cargo fetch` 等）。 |
| `scripts/demo-m5-rust.sh` | ~155 | 注入 `hello.rs` / `hellocargo` + `run-tests.sh`，起 QEMU，判 **`===M5-DEMO-PASS===`**。 |
| `scripts/demo-m6-selfbuild.sh` | ~300 | rootfs 挂载注入、`verify-m6-rootfs`、QEMU、停滞检测、`--subset` / `--boot-twice`。 |

**`patches/`** 下与 Starry 相关的 `*.patch` 文件数：**约 30+**（全仓 grep 统计；含 M1.5、各 T*、F* 等，不限于 selfhost 一条线）。

---

## 3. 测试与验收代码

- **`tests/selfhost/test_*.c`**：acceptance 与 Phase 2 扩展用例（Phase 2 文档曾记 **+20** 量级新测）。  
- **`scripts/run-tests-in-guest.sh`**（及 QEMU 包装脚本）：M1.5 类访客批量跑测。  
- **M1.5 init hook**：`patches/M1.5/` 等，使启动时 **`exec /opt/run-tests.sh`**。

---

## 4. M5 访客内编译「效果与效率」（合并自原 M5 专文）

- **效果**：Stage 0 工具链版本 → Stage 1 **`rustc hello.rs`**（`rustc exit=0`，运行 `/tmp/hello_rs`）→ Stage 2 **`cargo --offline build --release`**（单包 `hellocargo`，`cargo-build exit=0`）→ **`===M5-DEMO-PASS===`**。  
- **效率**：在 **QEMU TCG、单核、2 GiB** 典型配置下，`hellocargo` 的 **`Finished …` 常为十几秒量级**；与宿主原生不可 1:1 对比，**不能**用该数字外推 M6 整树编译时间。  
- **串口判读与 `Killed` 含义**：PASS 后脚本 **`kill -9` QEMU** 可出现 `Killed` 行，属预期。

---

## 5. M6 访客构建脚本要点（合并自原 M6 报告）

- **镜像**：`build-selfbuild-rootfs.sh` 产出 `tests/selfhost/rootfs-selfbuild-riscv64.img`；内含 **Alpine musl cargo**、**lld**、**ccwrap**、预 `cargo fetch`、烘焙 `StarryOS/.axconfig.toml` 等。  
- **访客脚本**：`/opt/build-starry-kernel.sh`（heredoc `GUESTSH`）；**勿**在 glibc bash 上全局 `export` musl 的 `LD_LIBRARY_PATH`；**`_run_cargo`** 仅包裹 cargo。  
- **链接器**：`CARGO_TARGET_RISCV64_ALPINE_LINUX_MUSL_LINKER=/opt/ccwrap/cc` + **`RUSTFLAGS=-fuse-ld=lld`**，避免 collect2 / 错误 libstdc++。  
- **演示**：`demo-m6-selfbuild.sh`；**`--subset`** → `===M6-SELFBUILD-SUBSET-PASS===`；完整 → `===M6-SELFBUILD-PASS===`。长跑建议 **`M6_STALL_SEC=0`** + 足够 **`M6_QEMU_TIMEOUT_SEC`**。  
- **改脚本后**：需 **loop 挂载** 将 `GUESTSH` 写回镜像内脚本，与仓库一致。

---

## 6. 宿主双编留档

**可复现的两次 `starryos` 构建 SHA**、arm-scmi 离线处理等仍记在 **`docs/KERNEL-BUILD-RECORD.md`**（未并入本文，以免与 git 提交强绑定）。

---

## 7. 样例日志（非 Markdown）

以下保留为 **原始串口/终端转储**，便于 diff：

- `docs/M5-DEMO-output.txt`  
- `docs/M2-demo-output.txt` / `docs/M2-real-compile-output.txt`  
- `docs/PHASE5-DEMO-output.txt`

---

*若需精确到 commit 的 diffstat，请对 `tgoskits` 子模块与本仓 `patches/` 使用 `git log --stat`。*
