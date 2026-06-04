# fix(starry): implement conservative riscv hwprobe

## 问题

RISC-V 用户态工具链会调用 `riscv_hwprobe` 查询 ISA/CPU 能力。StarryOS 当前对该 syscall 返回未实现，会在真实 cargo/rustc workload 中产生大量 `Unimplemented syscall: riscv_hwprobe` 日志噪音。

这不应该影响正确性，但会拉长反馈链路：长时间 M6 selfbuild 日志里关键错误容易被 syscall 噪音淹没，也不利于判断 guest 是否真的卡住。

## 根因

内核 syscall 分发表没有处理 Linux RISC-V ABI 的 `riscv_hwprobe`。用户态遇到 ENOSYS 后会退化，但每次调用都会进入未实现路径。

## 修复

- 在 StarryOS syscall 分发表中接入 `riscv_hwprobe`。
- 实现保守兼容语义：识别基本参数、校验 flags/用户指针，对未知 key 返回不宣称能力的结果。
- 不主动声明具体扩展能力，避免把 QEMU/平台能力暴露得过度激进。

## 使用原因

- syscall 层是 ABI 入口，修这里可以直接消除用户态工具链的 ENOSYS 噪音。
- 测试放到 `qemu-smp1/bugfix`，因为该问题和 SMP 本身无关，单核即可复现 ABI 行为。

## Test plan

- `git diff --check upstream/dev..HEAD`
- `cargo fmt --check`
- 新增 grouped case: `qemu-smp1/bugfix/bug-riscv-hwprobe`

待补：

- `cargo xtask clippy --package starry-kernel`
- `cargo xtask starry test qemu --arch riscv64 --test-group normal --test-case qemu-smp1/bugfix/bug-riscv-hwprobe`

## 风险

该实现是保守兼容，不暴露硬件扩展能力；风险是部分用户态不能利用优化路径，但不会因为错误宣称能力而走错路径。
