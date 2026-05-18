# Single CPU Baseline

## 目标

这条线先准备一个“稳定、可复现、可解释”的单 CPU StarryOS 版本，作为后续多 CPU 优化的对照组。

当前默认目标：

- arch/platform: `riscv64-qemu-virt`
- CPU mode: single CPU, QEMU `-smp 1`
- binary naming:
  - `binaries/riscv64-qemu-virt/starryos-singlecpu.bin`
  - `binaries/riscv64-qemu-virt/starryos-singlecpu.elf`
- status: M6 guest self-build 已通过，binary 和完整日志已放入本目录

## 为什么先用 RISC-V

前面的 M6 selfbuild、guest cargo build、多核 hello-world build 实验都基于 `riscv64-qemu-virt` 推进。先把这个目标收敛出稳定单核版本，能提供：

- 多 CPU 加速前后的可靠对照组
- host Linux QEMU 与 guest Starry QEMU 的同一套启动入口
- 后续 PR 测例和 bugfix 的最小复现背景

其它架构不排除，但需要单独补齐 binary、rootfs、QEMU 配置和日志。

## 交付物

| 类别 | 路径 | 状态 |
| --- | --- | --- |
| binary | `binaries/riscv64-qemu-virt/` | 已放入 guest-built `.elf/.bin` 和 SHA256 |
| host QEMU runbook | `runbooks/host-linux-qemu.md` | 已补运行模板，已完成一次 macOS host QEMU boot smoke |
| guest Starry QEMU runbook | `runbooks/guest-starry-qemu.md` | 已完成 nested smoke：guest 内 QEMU 启动内层 StarryOS userland |
| build/boot logs | `logs/` | 已放入 self-build、host QEMU、A/B 对比和 nested QEMU 日志 |
| M6 result report | `docs/m6-selfbuild-result.md` | 已写入 |
| bug trail | `docs/issue-trail.md` | 已更新 |
| bugfix summary | `docs/bugfixes.md` | 已更新 |
| PR plan | `docs/pr-plan.md` | 已更新 |
| PR cases | `tests/pr-cases.md` | 已写首版 |

## 验收标准

单 CPU baseline 当前状态：

1. 已有明确 source commit。
2. 已有 `starryos-singlecpu.bin` 和 `starryos-singlecpu.elf`。
3. 已有 SHA256。
4. 已有完整 guest self-build log，证明 kernel ELF 在 StarryOS guest 内产出。
5. 已完成一次 host QEMU boot smoke：新 `.bin` 能启动到 StarryOS userland/M6 init，并在 resume 模式打印 `===M6-SELFBUILD-PASS===`。
6. 已完成 guest Starry QEMU nested smoke：内层 StarryOS 打印 `===GUEST_BUILD_PASS===`。
7. PR 相关 bug 都应对应到一个测例或最小复现。

## 当前注意事项

- 单 CPU 使用 `-accel tcg,thread=single`，不涉及 QEMU RISC-V MTTCG 的 cross-hart LR/SC 问题。
- 所有多核实验结果应放在 `../multi-cpu/`，不要作为单核 baseline 的正确性依据。
- 如果 binary 从其它 worktree 拷贝进来，必须同时记录 source commit 和构建命令。
- 本次编译成功后，checkpoint tar 的 host 读回暴露 duplicate extent 问题；这属于文件系统 follow-up，不影响“guest cargo build 已产出 StarryOS kernel”这个结论。
