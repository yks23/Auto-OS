# BigLab-B Final Materials

更新时间：2026-06-04

本目录是杨凯森 BigLab-B 最终材料的入口目录文档。GitHub 上优先从这里阅读；PPT、报告、过程稿、复现脚本、CPU 曲线和日志证据都按多文件形式分开放置。

## 建议阅读顺序

1. `biglab-b-process-yang-kaisen.md`
   先看完整过程线：基础训练、AI/Harness、OS PR、单核尝试、多核性能、CPU 曲线、复现材料和后续思考。

2. `biglab-b-final-report-yang-kaisen.md`
   再看正式报告母稿：适合直接改成提交版报告。

3. `biglab-b-final-yang-kaisen-minimal.pptx` / `biglab-b-final-yang-kaisen-minimal.pdf`
   正式答辩优先使用的简约版 PPT。

4. `live-demo/README.md`
   上台 demo 命令入口，包括 `01` 到 `05` 五个脚本。

5. `cpu-util/parallelism-analysis.md`
   解释为什么 8 核不线性加速，以及 CPU 利用率图的证据口径。

6. `../../../success-pr/PR-TRACKING.md`
   PR 过程追踪和已合入/候选 PR 的历史状态。

## 目录地图

| 路径 | 内容 |
| --- | --- |
| `README.md` | 本入口文档，记录所有材料放置位置和使用顺序。 |
| `biglab-b-process-yang-kaisen.md` | 新整理的完整过程纪要，适合放“过程汇报”。 |
| `biglab-b-final-report-yang-kaisen.md` | 完整总结报告母稿。 |
| `biglab-b-final-ppt-outline-yang-kaisen.md` | PPT 页序、内容规划和口播稿。 |
| `biglab-b-final-yang-kaisen-minimal.pptx/pdf` | 简约版正式展示稿，当前答辩优先使用。 |
| `biglab-b-final-yang-kaisen.pptx/pdf` | 完整展示版。 |
| `Kaisen-report-fixed.pptx/pdf` | 基于旧版 PPT 修补后的版本，用于对照和备份。 |
| `*-contact-sheet.png` | PPT 缩略图预览，快速检查页序和版面。 |
| `cpu-util/` | CPU 曲线、并行受限分析、host/guest 对照图、采样 CSV 和摘要。 |
| `live-demo/` | 五个最终演示脚本和运行说明。 |
| `live-demo/out/` | 小型日志和测速摘要；rootfs/kernel 二进制是本地生成物，不上传。 |
| `../scripts/` | 生成 CPU 曲线、HVF guest build、fork/fileio/build-script wave 的辅助脚本。 |
| `../../../success-pr/` | PR tracking、已合入 PR 归档、候选 PR 草稿。 |

## 文件

- `biglab-b-final-report-yang-kaisen.md`
  完整总结报告。按老师要求覆盖 BigLab-A 简述、BigLab-B 实验 1~4、已合入 PR、重点 PR 分析、StarryOS 自举编译、多核性能瓶颈、教学反思和答辩口径。

- `biglab-b-process-yang-kaisen.md`
  完整过程纪要。按“基础训练 -> AI/Harness 闭环 -> OS PR -> 单核尝试 -> 多核性能 -> CPU 曲线 -> 复现材料 -> 后续思考”整理，可直接复制进报告过程部分或改成答辩口播。

- `biglab-b-final-ppt-outline-yang-kaisen.md`
  答辩 PPT 规划和口播稿。后续生成 PPTX 时应以此为内容源，避免继续沿用旧状态。

- `biglab-b-final-yang-kaisen.pptx`
  根据最新口径生成的最终答辩 PPT：BigLab-A 前置训练、BigLab-B Task 1 的 tg-arceos-tutorial 五个基础 exercise、Task 2 阶段 1 Harness、重点 PR 背景、self-build 速度 setting、CPU/阶段利用率图、成因拆解和 OS 课程设计思考。

- `biglab-b-final-yang-kaisen-minimal.pptx` / `biglab-b-final-yang-kaisen-minimal.pdf`
  简约版正式展示稿。当前答辩优先使用这一版，共 19 页；已修正 BigLab-B Task 1 / Task 2 阶段 1 的归属，补 3 页 PR 背景知识，并把端到端、编译并行、链接/串行尾段三种加速比拆开。

- `biglab-b-final-yang-kaisen-contact-sheet.png`
  最新 PPT 缩略图预览，便于快速检查页序和版面。

## 本地生成物说明

`live-demo/out/` 里曾生成过 rootfs、ELF、bin 等大文件，用于现场复现和本地验证。这些文件太大或可由脚本重新生成，不作为 GitHub 材料上传：

- `rootfs-*.img`
- `*.elf`
- `*.bin`

GitHub 上保留的是脚本、说明、PPT/PDF、图表、CSV/summary、小型日志和测速摘要。需要重新生成本地 rootfs/kernel 时，按 `live-demo/README.md` 的五步脚本执行。

## 当前状态口径

- 已合入 `rcore-os/tgoskits:dev` 的核心 PR：`#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926`。
- 主报告和 PPT 只把已合入 `dev` 的 OS PR 作为成果主表。
- StarryOS 自举编译、多核测速和 HVF 复现实验作为本地 demo / 实验过程证据，不计入已合入 PR 列表。
- StarryOS 8 核 guest self-build 最好数字：`331s`。
- 最慢 guest baseline：`951s`。
- macOS native release 参考：`CARGO_BUILD_JOBS=1` 为 `96s`，`CARGO_BUILD_JOBS=8` 为 `42s`，host 编译并行加速比 `96s / 42s = 2.29x`。这说明 Cargo 图有并行空间，但即使在 macOS 上也不会 8 核持续打满；guest 还承担 syscall、FS、scheduler、QEMU/HVF 边界和 guest userland 成本。
- Host CPU 曲线复现脚本：[run-host-build-cpu-curve.py](/Users/txc/code/Auto-OS/过程记录/最终材料/scripts/run-host-build-cpu-curve.py)，使用 `--profile-mode native-release` 采 macOS 正常 release；`--profile-mode guest-aligned` 只用于和 guest 演示 profile 对齐，不再混作 native release 结论。
- Live demo 五个脚本在 [final/live-demo](/Users/txc/code/Auto-OS/过程记录/最终材料/final/live-demo/README.md)，同时提供短入口 [live-demo](/Users/txc/code/Auto-OS/过程记录/最终材料/live-demo/README.md)；两边均支持 `--check`，用于上台前确认本机依赖、rootfs、kernel 输入和测速证据。默认稳定链路已验证：`01-build-starryos` 生成 `starryos-host-aarch64-smp1.bin`，`03-test-kernel-result` 进入 StarryOS userland 并打印 `===TEST-KERNEL-RESULT-PASS===`。验证日志：[01](/Users/txc/code/Auto-OS/过程记录/最终材料/final/live-demo/out/01-build-starryos-aarch64-smp1-j8-aligned-fast-20260529T182232.log) / [03](/Users/txc/code/Auto-OS/过程记录/最终材料/final/live-demo/out/03-test-kernel-result.log)。`02-guest-build-starryos` 默认使用 `QEMU_SMP=8`、`CARGO_BUILD_JOBS=8`、`RAYON_NUM_THREADS=8`，成功后打印 `===02-GUEST-BUILD-STARRYOS-PASS===`；`05-speed-ratios` 汇总或重跑 demo benchmark、guest 实际编译、macOS host 编译的 `1 -> 8` 并行测速比。
- 可报告 guest 端到端调优收益：`951 / 331 = 2.87x`。
- 严格对齐的 guest jobs-only 加速比：同一 optional-ddebug profile 下 `422 / 341 = 1.24x`。
- 链接/串行尾段收益不要说成纯 link-only benchmark。可报告为：`642 -> 515 = 1.25x` 关闭 LTO；`515 -> 427 = 1.21x` 降低 opt-level 并增大 codegen-units；合计 `642 -> 427 = 1.50x`，代表 LTO/codegen/link 尾段工作量缩短。
- 不应声称完整 cargo build 已达到 4x；4x 只在特定短链路如 fork/exec/wait wave 中成立。
