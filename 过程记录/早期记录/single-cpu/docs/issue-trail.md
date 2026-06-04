# Single CPU Issue Trail

本文件按顺序记录单 CPU baseline 准备过程中发现的问题、判断、修复和验证入口。当前先放已经知道的线索，后续每次跑出新日志再追加。

## 0. 目标架构收敛

- decision: 先用 `riscv64-qemu-virt`。
- reason: M6 selfbuild、guest cargo build 和前面的 SMP 实验都以 RISC-V 为主。
- impact: 单核 baseline 和多核实验可以共享 rootfs/构建上下文，便于比较。

## 1. 先要单核稳定对照

- symptom: 多核优化会同时引入速度变化和并发 bug，难以判断问题来自 build workload、kernel 还是 QEMU。
- decision: 先产出 `-smp 1` binary、host QEMU 日志和测试说明。
- result:
  - `single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin`
  - `single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.elf`
  - `single-cpu/logs/m6-selfbuild-guest-pass.log`
- evidence: guest 内 `cargo build --release` 完成，日志出现 `===M6-SELFBUILD-PASS===`。
- follow-up: 已补一次非交互 boot smoke，证明新 `.bin` 能启动到 StarryOS userland/M6 init；还需要补交互 shell/`ls /` smoke。

## 2. 已在 PR 线上暴露的单核相关 bug

这些问题不一定都属于 showtime baseline 本身，但都和 StarryOS 可运行性/测试稳定性有关，应在 PR 文档里关联：

| PR | 问题 | 当前状态 | 测例入口 |
| --- | --- | --- | --- |
| #692 | robust futex cleanup 遇到坏用户地址时需要容错 | 已提交 PR，clippy 修复已追加 | `test-futex-robust-list` |
| #693 | `vfork` + child-stack clone 的等待语义需要避免错误等待 | 已提交 PR，review 已解释 | `test-vfork` |
| #694 | IPv4-mapped IPv6 socket 支持和 accepted peer address 包装 | 已提交 PR，review fix 已补 | `bug-af-inet6-v4mapped` |
| #695 | rsext4 未初始化 inode bitmap 复用 | 已提交 PR，CI 绿 | 待补更小复现 |

## 3. 本次 M6 guest self-build 发现的文件系统读回问题

- symptom: guest 编译成功后，Linux host 直接读取 rootfs 里的 `/opt/tgoskits/.m6-checkpoints/target.tar` 失败，出现 `Input/output error`。
- evidence: `debugfs` 观察到 `target.tar` 相关 duplicate/overlapping extents；对复制出来的 rootfs 运行 `e2fsck -fy` 后，报告 duplicate extent mapping 和 multiply-claimed blocks。
- impact: 编译成功本身成立，因为日志在 checkpoint 前已经显示 cargo pass2 成功，并且修复复制镜像后能提取到最终 ELF；但大 tar checkpoint 的写回/读回路径需要单独作为 StarryOS 文件系统问题分析。
- workaround used for showtime: 只对 `.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img` 这个副本 fsck，然后从副本提取最终 `starryos` ELF 并转换成 `.bin`。
- follow-up: 设计更小的文件系统回归测例，优先复现“大文件顺序写入后 host ext4 读回 duplicate extent”。

## 4. 待补记录

- 单核 host QEMU 完整启动日志。
- guest Starry QEMU 的可行性结果。
- 每个 PR case 的最小运行命令。
- 文件系统 checkpoint 读回问题的最小复现和 PR 分区。
