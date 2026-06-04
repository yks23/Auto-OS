# Showtime-2 Helper Scripts

这些脚本支撑 BigLab-B 最终材料中的复现、测速和 CPU 曲线。正式演示优先使用 `showtime-2/final/live-demo/` 下的五个入口；本目录更多是分析和生成材料的底层工具。

## Host / Guest 编译曲线

| 脚本 | 用途 |
| --- | --- |
| `run-host-build-cpu-curve.py` | 在 macOS host 上跑 StarryOS 编译，并采集 cargo/rustc 进程树 CPU 曲线；支持 `native-release` 和 `guest-aligned` 两种 profile。 |
| `run-hvf-starryos-smp8-hostcpu-second.sh` | 跑 AArch64/HVF StarryOS guest `SMP=8` self-build，并按秒采集 QEMU 进程 CPU。 |
| `monitor-qemu-top-cpu.sh` | 用 macOS `top -pid` 采集指定 QEMU 进程 CPU，模拟“另一个终端看 top”的方式。 |
| `extract-hvf-host-cpu-util.py` | 把 QEMU 日志和 host CPU CSV 解析成 per-second CSV、summary 和 SVG 曲线。 |
| `start-smp8-top-two-terminal.sh` | 自动打开两个 macOS Terminal 窗口：一个跑 guest build，一个跑 `top` 采样。 |

## Workload 波形与短基准

| 脚本 | 用途 |
| --- | --- |
| `analyze-cargo-build-timeline.py` | 从 Cargo JSON timing 里生成 compile/artifact/build-script 时间线。 |
| `parse-hvf-build-log.js` | 解析 HVF guest build 日志中的阶段和 crate 进度。 |
| `run-hvf-cargo-buildscript-wave.sh` | 构造 build script 波形，用于分析 Cargo 早期门槛。 |
| `run-hvf-rustc-buildscript-wave.sh` | 构造 rustc/build-script 组合压力。 |
| `run-hvf-cargo-fingerprint-wave.sh` | 构造 Cargo fingerprint / wait / jobserver 相关波形。 |
| `run-hvf-forkexec-wave.sh` | fork/exec/wait 并行短基准。 |
| `run-hvf-fileio-wave.sh` | 文件写入、rename、metadata 等 FS 并行短基准。 |
| `run-hvf-guest-probe.sh` | 通用 guest probe runner。 |

## Rootfs / 调试辅助

| 脚本 | 用途 |
| --- | --- |
| `run-hvf-starryos-guest-build.sh` | 较底层的 HVF guest build runner，final demo 脚本会间接使用相关逻辑。 |
| `run-hvf-rust-sysroot-preflight.sh` | 检查 guest Rust sysroot / build-std 前置条件。 |
| `run-host-aligned-starryos-oracle.sh` | 历史 host-aligned 对照脚本，最终 CPU 曲线优先使用 `run-host-build-cpu-curve.py`。 |
| `debugfs-replace-hvf-auto-up1-j1.cmd` | debugfs 注入脚本片段。 |
| `hvf-auto-up1-j1-debug.sh` | 早期 UP/J1 调试入口。 |

## 输出位置

生成的最终图表和摘要主要放在：

- `showtime-2/final/cpu-util/`
- `showtime-2/final/live-demo/out/`

rootfs、ELF、bin 等本地生成物不上传到 GitHub；需要时重新运行 `showtime-2/final/live-demo/README.md` 中的演示脚本。
