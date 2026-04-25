# `docs/` 索引（自我编译 / Starry 相关）

大量专题已 **合并为三层**，便于按「路线 → 实现 → 现状」阅读：

| 顺序 | 文档 | 内容 |
|------|------|------|
| 1 | **[SELFHOST-ROADMAP-TASKS.md](./SELFHOST-ROADMAP-TASKS.md)** | **任务拆解**：M0–M6 阶梯、依赖顺序、关键路径、附录复现入口。 |
| 2 | **[SELFHOST-IMPLEMENTATION-SUMMARY.md](./SELFHOST-IMPLEMENTATION-SUMMARY.md)** | **核心实现**：patch 规模、关键脚本行数、F-ε/M5/M6 技术要点、样例日志索引。 |
| 3 | **[SELFHOST-STATUS-AND-IMPROVEMENTS.md](./SELFHOST-STATUS-AND-IMPROVEMENTS.md)** | **现状与改进**：里程碑表、风险边界、M6 注意项、后续优先级。 |

**仍保留的专题页（未并入三层，避免丢失演示细节）**

- **[DEMO.md](./DEMO.md)** — M5 收官、F-ε 原文、复现命令与路线图状态表。  
- **[REPRODUCE.md](./REPRODUCE.md)** — Docker-only 一键复现（英文）。  
- **[STARRYOS-GUEST-SMOKE.md](./STARRYOS-GUEST-SMOKE.md)** — 冒烟用盘与排障。  
- **[STARRYOS-KERNEL-BUILD-MATRIX.md](./STARRYOS-KERNEL-BUILD-MATRIX.md)** — 宿主/访客/矩阵构建路径。  
- **[KERNEL-BUILD-RECORD.md](./KERNEL-BUILD-RECORD.md)** — 双编 SHA 留档。  

**原始串口转储（`.txt`）**：`M5-DEMO-output.txt`、`M2-*.txt`、`PHASE5-DEMO-output.txt` 等。

---

*更细的 Phase / T* 任务表见仓库根下 `selfhost-orchestrator/`。*
