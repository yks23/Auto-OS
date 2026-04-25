# StarryOS 自举：目前状况与改进方法

本文合并原 **`SELFHOST-SIX-STAGES-AND-PROGRESS.md`**、**`STARRYOS-STATUS.md`（长文）**、**`M6-SELFBUILD-REPORT.md`** 中与 **现状、风险、下一步** 相关的内容；**任务拆解**见 [`SELFHOST-ROADMAP-TASKS.md`](./SELFHOST-ROADMAP-TASKS.md)，**实现与代码量**见 [`SELFHOST-IMPLEMENTATION-SUMMARY.md`](./SELFHOST-IMPLEMENTATION-SUMMARY.md)。

---

## 1. 里程碑总表（简版）

| 里程碑 | 含义 | 当前结论（以主线文档与脚本为准） |
|--------|------|----------------------------------|
| M0 | 宿主编可启动内核 ELF | ✅ |
| M1 | 宿主编内核 + 大量 musl 测试 ELF | ✅ |
| M1.5 | 访客跑 acceptance | ✅ **31/31 PASS**（见 [`SELFHOST-IMPLEMENTATION-SUMMARY.md`](./SELFHOST-IMPLEMENTATION-SUMMARY.md)；历史明细见 git 中已移除的 `docs/M1.5-final-results.md`；后续以你重跑为准） |
| M2 | 访客 `hello.c` | ✅ |
| M3 | 访客多文件 C / M3-equivalent | ✅；**完整 BusyBox（M3-real）** 仍可能有少量 fixup（`docs/DEMO.md`） |
| M4 | 访客自编译 musl | ⏳ 路线目标 |
| M5 | 访客 `cargo build` 小工程 | ✅ `===M5-DEMO-PASS===` |
| M6 | 访客编 starry 树 | 🔄 **脚本与镜像已具备**；**完整 PASS** 依赖长跑 QEMU；**`demo-m6-selfbuild.sh --subset`** 作快验 |

---

## 2. 仍须警惕的能力边界

下列来自历史 **STARRYOS-STATUS** 评估；**多数已在主线 patch 与 M1.5/M5 实测中缓解**，但下列条目在 **复杂 workload** 上仍可能暴露：

| 类别 | 说明 |
|------|------|
| **部分 syscall 语义偏弱** | `madvise`/`mremap` 简化、`setuid` 恒 root、大量 dummy fd（io_uring/bpf 等）——高级应用可能静默失败。 |
| **缺失 syscall** | `waitid`、`execveat`、`sem*`、`mq_*` 等仍可能缺或不全。 |
| **测试债务** | 个别 acceptance 用例曾记 **FAIL/SKIP**（如 LOCK_NB、setpriority）；需 follow-up 与主线是否「接受风险」对齐。 |
| **x86_64 自托管** | 曾有 **e820 / PCI MMIO** 类 boot 问题记录；riscv64 为 demo 主平台。 |

---

## 3. M6 专项：现状、易错点、改进

| 主题 | 说明 |
|------|------|
| **QEMU 极慢** | 全量 `starry-kernel` 在仿真下可达 **数小时**；应用 **`M6_STALL_SEC=0`** 避免「无串口输出误杀」，并拉大 **`M6_QEMU_TIMEOUT_SEC`**。 |
| **脚本与镜像不同步** | 改 `build-selfbuild-rootfs.sh` 内 `GUESTSH` 后须 **loop 挂载写回** `/opt/build-starry-kernel.sh`。 |
| **子集冒烟** | **`bash scripts/demo-m6-selfbuild.sh --subset`** → `===M6-SELFBUILD-SUBSET-PASS===`，适合 CI/日常。 |
| **sqlite / disk full 误报** | cargo 在部分 FS 上可能警告 **error 13**；demo **不应**仅据此杀 QEMU；若 **硬失败** 再查磁盘与 `CARGO_HOME` 布局。 |
| **完整 PASS 判据** | `.guest-runs/riscv64-m6/results.txt` 中含 **`===M6-SELFBUILD-PASS===`**（或 **`LIB-PASS`** 降级）。 |

---

## 4. 改进方法（按优先级）

1. **M6 完整盖章**：固定 **镜像版本 + commit**，在 **真机或 CI** 上长跑；产出 **`results.txt` 片段 + 耗时** 作为回归基线。  
2. **M3-real / M4**：在 M5 稳定前提下，按 **`COMPILE-MILESTONES.md`** 补齐 BusyBox / musl 的量化出口。  
3. **syscall 语义**：对「假成功」类逐项加 **测试或返回 `ENOSYS`**，减少静默错误（见历史 STATUS 表格）。  
4. **x86_64**：修复 axplat / e820 相关 boot 后再做 **双架构 selfhost** 演示。  
5. **文档与脚本**：大段复现保持 **`docs/REPRODUCE.md`（英文）** + 中文 **`SELFHOST-ROADMAP-TASKS.md` 附录**；避免再在 `docs/` 下复制第三份长文。

---

## 5. 冒烟与磁盘选择

交互 shell、外部命令、**勿用错 rootfs**（例如 M5 盘 init 占满串口）等，仍以 **`docs/STARRYOS-GUEST-SMOKE.md`** 为准。

---

## 6. 对外一句话

**宿主与访客 C/Rust 小编译（至 M5）已闭环；M6 以子集快验 + 完整长跑双轨推进；语义与架构债按上表逐项收敛。**

---

*历史长文 `docs/STARRYOS-STATUS.md` 已收缩为指向本文的短 stub，避免双源。*
