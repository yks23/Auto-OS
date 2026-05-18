# QEMU TCG Notes

## 核心结论

RISC-V QEMU TCG 在 `-smp N` 且多线程 TCG 模式下存在 LR/SC 相关正确性风险。它会影响 guest userspace 的原子操作，Rust/cargo build 正好大量依赖这些原子语义。

## 推荐用法

正确性优先：

```sh
qemu-system-riscv64 ... -smp 4 -accel tcg,thread=single
```

速度实验：

```sh
qemu-system-riscv64 ... -smp 4 -accel tcg,thread=multi
```

`thread=multi` 可以用来观察“真实并行是否能加速”，但不能作为最终 correctness 证明。

## 与内核 LR/SC context-switch fix 的关系

内核 `context_switch` 中使用类似 `sc.d t0, zero, (sp)` 的做法，可以处理同一 hart 上被抢占 LR/SC pair 的 reservation 清理问题。

但这不能修复 QEMU MTTCG 的跨 hart reservation invalidation 问题。两者是不同层面的 bug：

- context-switch fix: guest kernel 内部，同一 hart 的上下文切换语义。
- MTTCG issue: QEMU 模拟器对不同 hart 之间 LR/SC reservation 的建模。

## showtime 文档要求

所有多核日志必须记录：

- `-smp` 参数
- `-accel` 参数
- QEMU version
- workload
- 是否把结果用于 speed 或 correctness

