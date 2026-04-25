# 自我编译六阶段说明 · 当前进度 · 完成标准

本文把仓库里沿用的 **M1–M6 六阶里程碑**（与 `selfhost-orchestrator/COMPILE-MILESTONES.md`、`docs/DEMO.md` 等对齐）写清楚，并单独给出 **当前进度** 与 **怎样算「完成」**。

> **第零步 M0**（不占用「六阶」名额）：仅在 **宿主** 上用 cargo 编出可启动的 Starry 内核 ELF（空 patches 或基线集成），不涉及 QEMU 内编译。命令示例：`bash scripts/build.sh ARCH=riscv64`。

---

## 一、六个阶段分别做什么

六阶描述的是：**从「只在宿主能编」到「在访客里能编出越来越重的东西」，最终在内核环境里编内核**。

### 阶段一（M1 + M1.5）— 宿主集成与访客基线验收

| 子项 | 内容 | 典型产物 / 验证 |
|------|------|-----------------|
| **M1** | 在 **宿主** 上完成 T1–T5 等集成后的 **内核 ELF** + **selfhost 侧用户态测试**（多架构 musl 静态 ELF）的 **编译**。 | `bash scripts/integration-build.sh`；`tests/selfhost/out-<arch>/test_*` |
| **M1.5**（常视为 M1 的 **真验收**） | 把测试拷进 rootfs，在 **QEMU + Starry 访客** 里 **跑**上述测试，统计 PASS。 | `scripts/run-tests-in-guest.sh`；串口 / 日志里 `[TEST] … PASS` |

**阶段一完成含义**：不仅「能编」，还要「在真实 Starry 用户态下能跑足够多的基线用例」，否则后续在 guest 里跑 gcc/cargo 没有信任基础。

---

### 阶段二（M2）— 访客内 C 小程序（S0）

- **内容**：在访客 rootfs 内具备 **musl-gcc / binutils** 等，用 **一条命令链** 编译极小的 C 程序（如 `hello.c`），生成静态或约定好的 ELF，并 **执行** 看到预期输出。
- **衡量**：guest 内 `cc … -o /tmp/hello && /tmp/hello` 成功；演示脚本或文档中常见标记 **`===M2-PASS===`**。
- **依赖**：selfhost 镜像（如 `build-selfhost-rootfs.sh` 一类）、内核 fork/exec/pipe 等路径稳定。

---

### 阶段三（M3）— 访客内 C「大工程」（S1）

- **内容**：在访客里编译 **体量大得多** 的 C 工程，验证调度、内存、文件描述符、并行 `make` 等在高负载下的表现。路线图上典型目标是 **BusyBox 完整构建**；仓库里也记录过 **多文件 C 工程** 作为 **M3-equivalent** 的阶段性成果。
- **衡量**：BusyBox 路线：`make defconfig && make` 得到可用 `busybox`，`busybox --list` 等自检；或等价的多文件工程 + 运行自检。
- **与 M2 区别**：编译单元数量、链接规模、构建系统复杂度数量级上升。

---

### 阶段四（M4）— 访客内自编译 musl libc（S2 的一部分）

- **内容**：在访客内 **从源码配置并编译 musl**，得到可用的 `libc.a` / 安装树，证明 **C 工具链 + libc 源码** 在 Starry 上可完成自指构建。
- **衡量**：`configure && make && make install` 后 `file` / 简单链接小测通过（详见 `COMPILE-MILESTONES.md` 中 M4 行）。
- **说明**：与 **M5** 可部分并行规划，但依赖 rootfs 体量与磁盘空间；部分文档将 S2 粗分为「musl 深度」与「Rust 工具链」两条线。

---

### 阶段五（M5）— 访客内 Rust / cargo 小工程（S2）

- **内容**：rootfs 内提供 **rustc + cargo**（常见为 musl 或项目选定的工具链），在访客里 **`cargo new` / `cargo build --release`** 得到可执行文件并 **运行**。
- **衡量**：串口或日志中出现 **`===M5-DEMO-PASS===`**（以 `scripts/demo-m5-rust.sh` 为准）；证明 `cargo → rustc → (cc) → ld → 运行` 全链路在 guest 可行。
- **参考**：`docs/DEMO.md`、`tests/selfhost/build-selfhost-rootfs.sh`（`PROFILE=rust` 等）。

---

### 阶段六（M6）— 访客内编译 Starry 自身内核 / 发行根（S3 / S4）

- **内容**：在 **Starry 访客** 内对 **本仓库 / tgoskits 树** 执行 **针对 starry-kernel（及可选 starryos 链接阶段）的 cargo 构建**，即「内核环境里编内核」的自举闭环。延伸目标 **M6.S4** 为与宿主产物的 **可重复 / 哈希一致**（stretch）。
- **衡量（完整）**：`scripts/demo-m6-selfbuild.sh` 串口日志含 **`===M6-SELFBUILD-PASS===`**（完整 ELF）或 **`===M6-SELFBUILD-LIB-PASS===`**（仅 lib 阶段成功的降级标记）。
- **衡量（快速子集）**：同一脚本 **`--subset`** → **`===M6-SELFBUILD-SUBSET-PASS===`**（`metadata` + 若干 **`riscv64gc-unknown-none-elf` 的 `cargo check`**，用于确认工具链大致正常而无需数小时全量编内核；详见 `docs/M6-SELFBUILD-REPORT.md`）。
- **参考**：`docs/M6-SELFBUILD-REPORT.md`、`tests/selfhost/build-selfbuild-rootfs.sh`。

---

## 二、当前进度说明（截至文档维护时的仓库状态）

下列与 `docs/DEMO.md` 中「路线图状态」及 M6 相关文档 **对齐归纳**；若你本地分支更新，以 **实际跑出来的 PASS 标记** 为准。

| 里程碑 | 一句话 | 状态 |
|--------|--------|------|
| **M0** | 宿主编出可启动内核 ELF | ✅ 已达成 |
| **M1** | 宿主编内核 + 大量 musl 测试 ELF | ✅ 已达成 |
| **M1.5** | 访客跑 31 个 acceptance 测试 | ✅ 文档记载 **31/31 PASS**（见 `docs/M1.5-final-results.md`、`docs/DEMO.md`） |
| **M2** | 访客内 `hello.c` 全链 | ✅ 已达成 |
| **M3** | 访客内多文件 C / M3-equivalent | ✅ **M3-equivalent** 已记载；**完整 BusyBox（M3-real）** 仍可能需少量 fixup（见 `docs/DEMO.md`） |
| **M4** | 访客内自编译 musl | ⏳ 路线目标，**未作为主线关闭项写死为 PASS** |
| **M5** | 访客内 `cargo build` 小工程 | ✅ **已达成**（`docs/DEMO.md`） |
| **M6** | 访客内编 starry 内核 | 🔄 **工程与脚本已推进**：rootfs、ccwrap、musl host 链接、lld、`--subset` 快验、完整跑需 **QEMU 仿真下极长墙钟**；完整 **`M6-SELFBUILD-PASS`** 以你机器上 `results.txt` 为准（见 `docs/M6-SELFBUILD-REPORT.md`） |

**横向总结**：**宿主与访客 C/Rust「小编译」到 M5 已闭环**；**最重的一阶 M6** 依赖大镜像 + 长时间仿真，适合用 **`--subset`** 做频繁冒烟，用 **拉长 `M6_QEMU_TIMEOUT_SEC` + `M6_STALL_SEC=0`** 做完整盖章。

---

## 三、完成进度说明（怎样算「这一阶段做完了」）

### 1. 通用原则

- **每一阶**都应有 **可在 QEMU 串口或日志里核对** 的产物或标记（避免「CI 绿但现场编不出来」）。
- **宿主阶段（M0–M1）**：以 `scripts/build.sh` / `integration-build.sh` / `tests/selfhost` 的 make 结果为准。
- **访客阶段（M1.5 起）**：以 **指定 rootfs 镜像 + 指定 demo 脚本** 的退出码与日志关键字为准。

### 2. 各阶「完成」的可操作 checklist

| 阶段 | 建议「完成」判据 |
|------|------------------|
| **M1** | 双架构（或你关心的架构）内核 ELF + 约定测试 ELF 全部编出且无失败退出码。 |
| **M1.5** | `run-tests-in-guest` 类流程下 **PASS 数达到路线图约定**（历史上曾用 ≥25/31 作为 Phase 1 真出口；当前文档有 **31/31** 记载则以团队最新共识为准）。 |
| **M2** | 访客内单文件 C 编译运行；日志含 **M2-PASS** 或等价记录。 |
| **M3** | BusyBox 或等价大工程 **构建 + 自检** 达到里程碑表中的量化指标（如 `busybox --list` 数量等）。 |
| **M4** | musl 安装树与静态库产物齐备，并有最小链接验证。 |
| **M5** | **`===M5-DEMO-PASS===`**（或 CI 中等价 job 绿）。 |
| **M6** | **`===M6-SELFBUILD-PASS===`**；若仅验证工具链可用 **`===M6-SELFBUILD-SUBSET-PASS===`** 作为 **子里程碑**，不替代完整自举。 |
| **M6.S4（stretch）** | guest 与 host 产物哈希一致或满足项目定义的 reproducibility 策略。 |

### 3. 进度汇报时可以用的口径

- **整线完成度**：可用「六阶中已盖章几阶 / 是否剩 M4、M6-full」描述。
- **M6 单列**：建议同时报 **`subset` 是否稳定 PASS** 与 **full PASS 是否已在本机或 CI 跑出**，避免把「脚本好了」与「完整仿真跑完」混为一谈。

---

## 四、相关索引（深入细节请读这些）

| 文档 / 路径 | 用途 |
|-------------|------|
| `selfhost-orchestrator/COMPILE-MILESTONES.md` | 每阶「小编译目标」表格与示例命令 |
| `selfhost-orchestrator/ROADMAP.md` | Phase 与任务 ID、依赖图 |
| `docs/DEMO.md` | M5 演示与路线图状态表 |
| `docs/M6-SELFBUILD-REPORT.md` | M6 复现、子集、已知问题 |
| `docs/STARRYOS-STATUS.md` | 历史现状评估与 backlog（注意 pin 日期可能旧于主线） |
| `docs/M1.5-final-results.md` | M1.5 真验收结果 |

---

*若六阶命名与某次会议纪要不一致，以 `selfhost-orchestrator/COMPILE-MILESTONES.md` 与当前 demo 脚本中的 PASS 字符串为实施准绳。*
