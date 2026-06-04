# 过程记录

更新时间：2026-06-04

本目录统一合并原来的 `showtime/` 和 `showtime-2/`。后续查阅过程材料、展示材料、复现脚本和性能证据，都从这里进入。

## 目录结构

| 路径 | 来源 | 内容 |
| --- | --- | --- |
| `早期记录/` | 原 `showtime/` | RISC-V M6 self-build、单核路线、多核早期探索、QEMU TCG 说明、早期演示稿和日志。 |
| `最终材料/` | 原 `showtime-2/` | BigLab-B 最终报告/PPT、过程汇报、macOS AArch64/HVF self-build、CPU 曲线、live demo、测速脚本。 |

## 推荐入口

1. [最终材料/final/README.md](最终材料/final/README.md)
   最终答辩材料总入口：报告、PPT、过程稿、CPU 曲线、demo 和本地生成物说明。

2. [最终材料/final/biglab-b-process-yang-kaisen.md](最终材料/final/biglab-b-process-yang-kaisen.md)
   完整过程汇报，可直接用于报告“过程记录”部分。

3. [最终材料/final/biglab-b-final-report-yang-kaisen.md](最终材料/final/biglab-b-final-report-yang-kaisen.md)
   正式报告母稿。

4. [最终材料/final/biglab-b-final-yang-kaisen-minimal.pdf](最终材料/final/biglab-b-final-yang-kaisen-minimal.pdf)
   简约版正式展示稿 PDF。

5. [最终材料/final/live-demo/README.md](最终材料/final/live-demo/README.md)
   上台演示的五个脚本入口。

6. [最终材料/final/cpu-util/parallelism-analysis.md](最终材料/final/cpu-util/parallelism-analysis.md)
   8 核 CPU 利用率和并行受限分析。

7. [早期记录/README.md](早期记录/README.md)
   早期单核/多核探索的总入口。

## 本地生成物

`最终材料/final/live-demo/out/` 下的 rootfs、ELF、bin 等大文件不上传到 Git；它们可由 demo 脚本重新生成。早期记录里的已追踪小型二进制和日志保留，用于复核当时的 self-build 结果。

## 目录合并说明

Git 中已经不再使用 `showtime/` 和 `showtime-2/` 作为材料入口。若本地仍看到旧目录，一般是因为里面残留未追踪的临时日志、备份 PPT 或 rootfs 生成物；这些不是本次统一后的 Git 材料结构。

