# Multi CPU Progress

## 目标

这条线研究“真正多核并行”的 guest build 加速，而不是让多核串行跑。当前重点是 StarryOS guest 内执行小型 cargo build 时，`CARGO_BUILD_JOBS>1` 是否能稳定提速，以及内核需要修哪些同步/调度/内存管理 bug。

## 当前已知进展

- target: `riscv64-qemu-virt`
- speed signal workload: 小型 hello-world cargo workspace
- speed signal QEMU mode: `-smp 4 -accel tcg,thread=multi`
- observed speed result:
  - `-j1`: 约 176s
  - `-j4`: 约 62s
  - speedup: 约 2.8x
- fresh 8-HART raw CPU result with the guest-built kernel:
  - same kernel/rootfs/workload, only `tcg,thread=single` vs `tcg,thread=multi`
  - workers=4: `769171us -> 297609us`, about `2.58x`
  - workers=8: `764731us -> 310878us`, about `2.46x`
- full M6 cargo stage speed signal:
  - `SMP=8 + thread=multi + CARGO_BUILD_JOBS=1`: `starry-kernel lib` in `187m44s`
  - `SMP=8 + thread=multi + CARGO_BUILD_JOBS=4`: `starry-kernel lib` in `84m16s`
  - speedup: about `2.23x` for this real StarryOS cargo stage
- correctness workload: M6 guest self-build early kernel-lib stage
- correctness QEMU mode: `-smp 4 -accel tcg,thread=single`
- latest status: `SMP=8 + jobs=1` 已完整产出 guest-built StarryOS kernel 并通过 boot smoke；`jobs=4` 已证明 `starry-kernel lib` 阶段加速，但后续 pass1 仍会触发 guest cargo/rustc `Segmentation fault`，所以还不能宣称 full M6 `jobs=4/8` 已完成。
- newest correctness narrowing: `SMP=8 + thread=single + jobs=4` 的 pass2
  snapshot 已把问题收敛到两个 OS 路径：非 thread context usercopy 不能 panic，
  blocking mutex unlock 不能在 waiter 真正拿到 guard 前发布 owner。当前修复版
  已越过旧 72s/149s/223s/846s 崩溃窗口，继续编译到 `clap_builder v4.6.0`
  后在 host 1265s 上限停止，没有 panic/trap/FATAL/error。

## 当前实验性 kernel changes

这些改动目前只作为实验线索记录，不等于已经适合 PR：

- `os/StarryOS/kernel/src/syscall/sync/futex.rs`
  - 支持 `FUTEX_PRIVATE_FLAG`
- `os/arceos/modules/axsync/src/mutex.rs`
  - mutex unlock 从 owner handoff 改成先 store 0 再 notify_one；由于 owner
    是 task id，guard 改为 non-Send，禁止跨任务释放
- `os/StarryOS/kernel/src/mm/access.rs`
  - usercopy 入口检查 StarryOS thread context；page-fault path 避免重入已经
    持有的 process address-space lock；零长度 usercopy 直接 no-op
- `os/arceos/modules/axtask/src/api.rs`
  - 暴露 `resched_if_needed()`，让用户态 timer interrupt 只在 `need_resched` 置位时做调度
- `os/StarryOS/kernel/src/pseudofs/proc.rs`
  - `/proc` 遍历时跳过 kernel task，避免把 StarryOS user thread context 强行套到 GC/migration task 上

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

- `docs/true-acceleration-readiness.md`
- `docs/starryos-concurrent-selfbuild.md`
