# Multi CPU Progress

## 目标

这条线研究“真正多核并行”的 guest build 加速，而不是让多核串行跑。当前重点是 StarryOS guest 内执行小型 cargo build 时，`CARGO_BUILD_JOBS>1` 是否能稳定提速，以及内核需要修哪些同步/调度/内存管理 bug。

## 当前已知进展

- target: `riscv64-qemu-virt`
- QEMU mode tested: `-smp 4 -accel tcg,thread=multi`
- workload: 小型 hello-world cargo workspace
- observed result:
  - `-j1`: 约 176s
  - `-j4`: 约 62s
  - speedup: 约 2.8x
- status: 有加速信号，但样本数还少，需要重复跑和更重 workload 验证。

## 当前实验性 kernel changes

这些改动目前只作为实验线索记录，不等于已经适合 PR：

- `os/StarryOS/kernel/src/syscall/sync/futex.rs`
  - 支持 `FUTEX_PRIVATE_FLAG`
- `os/arceos/modules/axsync/src/mutex.rs`
  - mutex unlock 从 owner handoff 改成先 store 0 再 notify_one

已构建过的 SMP4 kernel 路径：

- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.bin`
- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.elf`

后续如果要作为 showtime artifact，需要拷贝到：

- `binaries/riscv64-qemu-virt/starryos-smp4.bin`
- `binaries/riscv64-qemu-virt/starryos-smp4.elf`

并补 SHA256、source commit、构建命令和启动日志。

## 正确性风险

RISC-V QEMU TCG 的 MTTCG 下存在 LR/SC reservation 建模问题，可能让 guest userspace atomic CAS 出现错误。这意味着：

- `-accel tcg,thread=multi` 可以作为速度实验。
- 它不能单独作为正确性证明。
- 若目标是 correctness，QEMU TCG SMP 应使用 `-accel tcg,thread=single`，或改用真硬件/正确模拟器。

详细说明见：

- `docs/qemu-tcg-notes.md`

## 并发 selfbuild runbook

如果要测试“StarryOS guest 内并发编译 StarryOS”，按这份方案推进：

- `docs/starryos-concurrent-selfbuild.md`
