# Multi CPU Blockers

## B1. QEMU RISC-V MTTCG LR/SC correctness

- severity: high for correctness, medium for speed experiment
- symptom: RISC-V QEMU TCG 多线程模式下，跨 hart LR/SC reservation invalidation 建模不正确。
- impact: guest userspace atomic CAS 可能错误成功，Rust build 这类高度依赖原子的 workload 可能被破坏。
- mitigation:
  - correctness run 用 `-accel tcg,thread=single`
  - speed experiment 可以跑 `-accel tcg,thread=multi`，但必须标注风险
  - 最终正确性应在真硬件或正确模拟器上确认

## B2. guest cargo build 重 I/O 和并发压力

- severity: high
- symptom: 大型 guest cargo build 曾需要 `CARGO_BUILD_JOBS=1`、`RAYON_NUM_THREADS=1` 来绕开 SMP 内核 page fault/重 I/O 问题。
- impact: M6 selfbuild 不能只看 hello-world，小 workload 过了不代表 selfbuild 过。
- next:
  - 先从 hello-world 多轮 benchmark 扩到中等 workspace。
  - 再回到 M6 selfbuild。
  - 每个 panic/trap 都要保存完整 log。

## B3. futex private/shared key

- severity: medium/high
- symptom: 多线程 userspace runtime 会大量使用 futex，private futex 和 shared futex 的 key 语义不清会造成 wake miss 或错误共享。
- experiment: 支持 `FUTEX_PRIVATE_FLAG`。
- next:
  - 写 futex private/shared regression。
  - 验证 pthread/cargo workload。

## B4. mutex unlock wakeup ordering

- severity: medium/high
- symptom: unlock 时如果 owner handoff 和 wake 顺序不合理，可能造成 waiter 看到状态不一致或丢 wake。
- experiment: unlock 先 store unlocked，再 notify one waiter。
- next:
  - 写内核/用户态压力测例。
  - 对比单核、多核、MTTCG 和 `thread=single`。

## B5. benchmark 证据不足

- severity: medium
- symptom: 目前 hello-world 只有一组初始数据。
- next:
  - 每个配置至少 5 次。
  - 记录 raw CSV。
  - 区分 cold build、incremental build、cache 命中情况。

## B6. SMP4 M6 early allocation panic

- severity: high
- symptom: 完整 M6 `-smp 4 -accel tcg,thread=multi CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4` 在约 13 秒内失败，日志显示 Rust allocation panic：

```text
memory allocation of 8912904 bytes failed
```

- evidence:
  - `showtime/multi-cpu/logs/m6-smp4-mttcg-j4.log`
  - `showtime/multi-cpu/logs/m6-smp4-mttcg-j4.done`
- impact: 当前还不能进入 M6 full cargo 编译阶段，因此不能讨论 4 核 M6 full build speedup。
- next:
  - 用 `M6_TCG_THREAD=single` + `--subset` 跑同样 `-smp 4/jobs=4`，先判断是否 MTTCG 特有。
  - 如 thread-single 也失败，继续缩小到 one-crate 或 toolchain sanity 阶段，定位是 StarryOS SMP 内存分配、tmpfs、还是 rust runtime 初始化压力。
  - 如 thread-single 通过，再把 MTTCG 风险单独标成 speed-only blocker。
