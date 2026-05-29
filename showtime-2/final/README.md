# BigLab-B Final Materials

更新时间：2026-05-30

本目录整理杨凯森 BigLab-B 最终答辩材料的文本母稿。

## 文件

- `biglab-b-final-report-yang-kaisen.md`
  完整总结报告。按老师要求覆盖 BigLab-A 简述、BigLab-B 实验 1~4、已合入 PR、重点 PR 分析、StarryOS 自举编译、多核性能瓶颈、教学反思和答辩口径。

- `biglab-b-final-ppt-outline-yang-kaisen.md`
  答辩 PPT 规划和口播稿。后续生成 PPTX 时应以此为内容源，避免继续沿用旧状态。

- `biglab-b-final-yang-kaisen.pptx`
  根据最新口径生成的最终答辩 PPT：BigLab-A 占位、Task 1 框架、Harness 两阶段、重点 PR 背景、self-build 速度 setting、CPU/阶段利用率图和成因拆解。

- `biglab-b-final-yang-kaisen-minimal.pptx` / `biglab-b-final-yang-kaisen-minimal.pdf`
  简约版正式展示稿。当前答辩优先使用这一版，共 18 页；已补 BigLab-A 任务结构、3 页 PR 背景知识，并把端到端、编译并行、链接/串行尾段三种加速比拆开。

- `biglab-b-final-yang-kaisen-contact-sheet.png`
  最新 PPT 缩略图预览，便于快速检查页序和版面。

## 当前状态口径

- 已合入 `rcore-os/tgoskits:dev` 的核心 PR：`#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926`。
- 主报告和 PPT 只把已合入 `dev` 的 OS PR 作为成果主表。
- StarryOS 自举编译、多核测速和 HVF 复现实验作为本地 demo / 实验过程证据，不计入已合入 PR 列表。
- StarryOS 8 核 guest self-build 最好数字：`331s`。
- 最慢 guest baseline：`951s`。
- Host 对齐参考：`29s`，同一份 StarryOS 源码、同一 AArch64/SMP8 kernel 配置、同一 no-LTO/opt0/cgu256、slab/no-dynamic-debug profile，只把 cargo/rustc 从 StarryOS guest 移到 macOS host；同口径 `CARGO_BUILD_JOBS=1` 为 `85s`，host 编译并行加速比 `85s / 29s = 2.93x`。这说明 Cargo 图在同构建任务下有并行空间，但不能把它当成 guest 内 speedup；guest 还承担 syscall、FS、scheduler、QEMU/HVF 边界和 guest userland 成本。
- Host 对齐参考复现脚本：[run-host-aligned-starryos-oracle.sh](/Users/txc/code/Auto-OS/showtime-2/scripts/run-host-aligned-starryos-oracle.sh)；日志：[j1](/Users/txc/code/Auto-OS/showtime-2/logs/host-starryos-aligned-aarch64-smp8-j1-20260529T175427-aligned-j1.log) / [j8](/Users/txc/code/Auto-OS/showtime-2/logs/host-starryos-aligned-aarch64-smp8-j8-20260529T175620-aligned-j8.log)。
- Live demo 四个脚本在 [live-demo](/Users/txc/code/Auto-OS/showtime-2/final/live-demo/README.md)；默认稳定链路已验证：`01-build-starryos` 生成 `starryos-host-aarch64-smp1.bin`，`03-test-kernel-result` 进入 StarryOS userland 并打印 `===TEST-KERNEL-RESULT-PASS===`。验证日志：[01](/Users/txc/code/Auto-OS/showtime-2/final/live-demo/out/01-build-starryos-aarch64-smp1-j8-aligned-fast-20260529T182232.log) / [03](/Users/txc/code/Auto-OS/showtime-2/final/live-demo/out/03-test-kernel-result.log)。多核/guest self-build 路线仍由 `02-guest-build-starryos` 和历史 8 核日志支撑。
- 可报告 guest 端到端调优收益：`951 / 331 = 2.87x`。
- 严格对齐的 guest jobs-only 加速比：同一 optional-ddebug profile 下 `422 / 341 = 1.24x`。
- 链接/串行尾段收益不要说成纯 link-only benchmark。可报告为：`642 -> 515 = 1.25x` 关闭 LTO；`515 -> 427 = 1.21x` 降低 opt-level 并增大 codegen-units；合计 `642 -> 427 = 1.50x`，代表 LTO/codegen/link 尾段工作量缩短。
- 不应声称完整 cargo build 已达到 4x；4x 只在特定短链路如 fork/exec/wait wave 中成立。
