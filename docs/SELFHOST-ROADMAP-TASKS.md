# StarryOS 编译自举：任务拆解路线

本文说明 **如何把「宿主编内核」拆成可验收的阶梯**，直到 **访客内 cargo 编内核（M6）**。与 `selfhost-orchestrator/COMPILE-MILESTONES.md`、`ROADMAP.md` 一致，但只保留 **任务拆解逻辑**，不展开 patch 细节（见 [`SELFHOST-IMPLEMENTATION-SUMMARY.md`](./SELFHOST-IMPLEMENTATION-SUMMARY.md)）。

---

## 1. 拆解原则

1. **每一阶都有「在 QEMU 里能指认的产物」**——避免「合并了 PR 但现场编不出来」。  
2. **先宿主、再访客；先跑测试、再跑编译器；先小程序、再大工程；最后才整仓 cargo**。  
3. **瓶颈前置**：若 fork/exec/wait 或文件锁在访客里是假的，**M1.5 与 M5 会直接失败**，不必等到 M6 才发现。

---

## 2. 总览：从 M0 到 M6 的依赖链

```
M0 宿主内核 ELF
  → M1 宿主 + 测试 ELF 编译
      → M1.5 访客跑基线测试（真验收）
          → M2 访客 C 单文件（S0）
              → M3 访客 C 大工程 / BusyBox（S1）
                  → M4 访客自编译 musl（可选深度）
                      → M5 访客 cargo 小工程（S2）
                          → M6 访客 cargo 编 starry 树（S3/S4）
```

**M0**：仅宿主 `cargo` 编 `starryos`，证明工具链与 `tgoskits` 布局可用。  
**M1**：在 T1–T5 等集成前提下，**宿主**编内核 + **大量 musl 测试 ELF**（`integration-build.sh` + `tests/selfhost`）。  
**M1.5**：把测试放进 rootfs，**QEMU 内跑**，统计 PASS；这是 Phase 1 的 **真出口**。  
**M2–M3**：证明 **musl-gcc 工具链** 在 Starry 上可用且可承压。  
**M4**：musl 自举（与 M5 可部分并行规划）。  
**M5**：**Rust 工具链** 在访客内 `cargo`/`rustc` 全链（`demo-m5-rust.sh`）。  
**M6**：对 **本树** `cargo build` starry-kernel / starryos（`demo-m6-selfbuild.sh`，含 `--subset` 快验）。

---

## 3. 各阶任务包（做什么、依赖谁）

| 阶 | 任务包 | 依赖 / 输入 |
|----|--------|--------------|
| **M1** | T1–T5 等 syscall/资源类 patch 集成；宿主编测。 | 宿主 Rust、子模块 `tgoskits`、patch 应用流程。 |
| **M1.5** | rootfs 含 BusyBox + 测试二进制；`run-tests-in-guest` 或 init hook。 | M1 产物、镜像构建、`/opt/run-tests.sh` 等。 |
| **M2** | selfhost **minimal** 镜像；guest 内 `cc hello.c`。 | M1.5 证明 exec 链基本可用；T10 类 rootfs 脚本。 |
| **M3** | 多文件 C 或 BusyBox `make`。 | M2、磁盘与内存、并行 `make` 稳定性。 |
| **M4** | musl 源码 `configure && make`。 | M3 级 C 工具链成熟度、磁盘空间。 |
| **M5** | **rust profile** rootfs（`build-selfhost-rootfs.sh PROFILE=rust`）；`demo-m5-rust.sh`。 | **F-ε 级 vfork/posix_spawn/execve** 与地址空间修复（见实现总结）。 |
| **M6** | **selfbuild** 大镜像（Debian + Alpine musl cargo、`build-selfbuild-rootfs.sh`）；`demo-m6-selfbuild.sh`。 | M5 级能力 + **ccwrap、lld、CARGO_HOME、访客脚本** 等（见现状文档）。 |

任务 ID（T6、T7、T8…）与 Phase 的对应关系以 **`selfhost-orchestrator/ROADMAP.md`** 为准；上表只保留 **与「能编」直接相关的拆解顺序**。

---

## 4. 关键路径（曾卡在哪里）

历史上 **`fork + execve + wait` 在 shell 里跑外部命令死锁** 会 **同时阻塞 M1.5、M2、M5**——因此路线图上把 **F-α / F-β / F-γ / F-ε** 等基础修复放在 **扩大编译任务之前**。  
**M6** 在 M5 之后又依赖 **musl 宿主 rustc 与 glibc clang 混用、collect2、QEMU 仿真墙钟** 等，故单独成阶并允许 **`--subset`** 子里程碑。

---

## 5. 附录：一键复现（Docker）

宿主只需 **Docker**；完整命令与平台说明仍以英文 **`docs/REPRODUCE.md`** 为准。最小心智模型：

```bash
git clone --recurse-submodules https://github.com/yks23/Auto-OS.git && cd Auto-OS
bash scripts/reproduce-all.sh   # 或按 REPRODUCE.md 分步
```

内部顺序概览：`docker build` → 容器内 `scripts/build.sh ARCH=riscv64` →（可选）M5/M6 所需 rootfs 与 `demo-*.sh`。

---

## 6. 延伸阅读（仓库内）

| 路径 | 内容 |
|------|------|
| `selfhost-orchestrator/COMPILE-MILESTONES.md` | 每阶「小编译目标」表格与示例命令 |
| `selfhost-orchestrator/ROADMAP.md` | Phase、T* 任务、checkpoint |
| `docs/REPRODUCE.md` | Docker-only 复现（英文） |
| `docs/DEMO.md` | M5 收官与 F-ε 背景摘要 |

---

*任务拆解以「可验证里程碑」为第一目标；代码与脚本体量见 [`SELFHOST-IMPLEMENTATION-SUMMARY.md`](./SELFHOST-IMPLEMENTATION-SUMMARY.md)。*
