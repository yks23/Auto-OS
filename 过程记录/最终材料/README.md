# 最终材料索引

本目录来自原 `showtime-2/`，现在统一放在 `过程记录/最终材料/` 下。它保存 BigLab-B 最终报告、PPT、过程汇报、live demo、CPU 曲线和复现脚本。

## 主要入口

| 路径 | 内容 |
| --- | --- |
| `final/README.md` | 最终答辩材料总入口。 |
| `final/biglab-b-process-yang-kaisen.md` | 完整过程记录和口播稿。 |
| `final/biglab-b-final-report-yang-kaisen.md` | 正式报告母稿。 |
| `final/biglab-b-final-yang-kaisen-minimal.pptx/pdf` | 简约版正式展示稿。 |
| `final/biglab-b-final-yang-kaisen.pptx/pdf` | 完整展示版。 |
| `final/cpu-util/` | CPU 利用率图、host/guest 对照、秒级采样数据。 |
| `final/live-demo/` | 最终上台演示脚本。 |
| `live-demo/` | 短路径 wrapper，转发到 `final/live-demo/`。 |
| `scripts/` | 生成 CPU 曲线、HVF guest build、fork/fileio/build-script wave 的辅助脚本。 |
| `pr-report.md` | TGOSKit / StarryOS PR 汇报索引。 |
| `m6-8core-status.md` | 8 核 M6 / self-build 阶段状态记录。 |

## 推荐阅读顺序

1. `final/README.md`
2. `final/biglab-b-process-yang-kaisen.md`
3. `final/biglab-b-final-report-yang-kaisen.md`
4. `final/cpu-util/parallelism-analysis.md`
5. `final/live-demo/README.md`

## 复现入口

```bash
bash 过程记录/最终材料/final/live-demo/01-build-starryos --check
bash 过程记录/最终材料/final/live-demo/02-guest-build-starryos --check
bash 过程记录/最终材料/final/live-demo/03-test-kernel-result --check
bash 过程记录/最终材料/final/live-demo/04-try-kernel --check
bash 过程记录/最终材料/final/live-demo/05-speed-ratios --check
```

## 大文件说明

`final/live-demo/out/` 下的 `rootfs-*.img`、`*.elf`、`*.bin` 是本地生成物，不上传到 Git。保留在 Git 中的是说明、脚本、小型日志、CSV、图表、PPT/PDF 和报告文本。
