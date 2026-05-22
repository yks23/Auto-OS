# Hello World Build Benchmark

## 目的

用小型 hello-world cargo workspace 验证 guest StarryOS 中多核 cargo build 是否真的有速度提升。

## 当前数据

| run | target | qemu cpu | qemu accel | cargo jobs | result | time |
| --- | --- | --- | --- | --- | --- | --- |
| initial-1 | `riscv64-qemu-virt` | `-smp 1` | TCG | `-j1` | pass | 176s |
| initial-2 | `riscv64-qemu-virt` | `-smp 4` | `tcg,thread=multi` | `-j4` | pass | 62s |

粗略 speedup: `176 / 62 = 2.84x`

## 当前结论

这个结果说明并行路径有真实加速信号，不是“多核但串行”。不过目前还不能作为最终结论，原因：

- 样本数太少。
- workload 很小，不能代表 M6 selfbuild。
- `tcg,thread=multi` 在 RISC-V 上存在 LR/SC 正确性风险。
- 还没有和 `-accel tcg,thread=single -smp 4` 的 correctness 模式做完整对照。

## 下一轮 benchmark 计划

每个组合至少跑 5 次：

| case | qemu cpu | qemu accel | cargo jobs | purpose |
| --- | --- | --- | --- | --- |
| baseline | `-smp 1` | default/single TCG | `-j1` | 单核对照 |
| smp correctness | `-smp 4` | `tcg,thread=single` | `-j4` | 多核语义但 TCG 串行，观察 correctness |
| smp speed | `-smp 4` | `tcg,thread=multi` | `-j4` | 真并行速度实验 |
| stress | `-smp 4` | `tcg,thread=multi` | `-j8` | 压力上限，不作为稳定配置 |

## 需要记录的字段

- source commit
- kernel binary checksum
- rootfs checksum
- QEMU version
- command line
- cargo build command
- wall time
- pass/fail
- kernel panic/trap/signals

