# fix(starry): expose SMP CPU topology in sysfs

## 问题

StarryOS SMP kernel 已能以 4/8 HART 启动，但用户态 CPU 拓扑暴露不完整。工具链和脚本会看到不一致的 CPU 数，例如 kernel banner 是 `smp = 8`，但 guest `nproc` 报告较小值。

这会误导 cargo/rayon 默认并行度，也会让验收时难以证明“内核看到的 CPU”和“用户态看到的 CPU”是一致的。

## 根因

`/proc/cpuinfo` 和 affinity/status 路径在最新 `upstream/dev` 已有基础修复，但 `/sys/devices/system/cpu/` 仍缺少 Linux 常见的 `online/possible/present` 拓扑文件。部分用户态会通过 sysfs 读取 CPU topology。

## 修复

- 在 sysfs 中新增 `/sys/devices/system/cpu/online`、`possible`、`present`。
- 暴露 `cpuN/online`，内容基于 `ax_hal::cpu_num()`。
- 扩展 qemu-smp4 affinity regression，检查默认 affinity、`/proc/self/status`、`/proc/cpuinfo` 和 sysfs CPU topology 至少覆盖 4 个 CPU。

## 使用原因

- sysfs 是用户态发现 CPU topology 的标准入口之一，和 procfs/affinity 互补。
- test 放在 qemu-smp4，因为该行为必须在多核配置下才能证明。

## Test plan

- `git diff --check`
- `cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml`
- CMake configure for `qemu-smp4/affinity/bug-proc-status-affinity`

待补：

- `cargo xtask starry test qemu --arch riscv64 --test-group normal --test-case qemu-smp4/affinity/bug-proc-status-affinity`

## 风险

当前实现把所有已启动 CPU 都作为 online/possible/present 暴露；暂不支持 CPU hotplug。对当前 QEMU SMP 平台这是正确的，未来热插拔需要另行扩展。
