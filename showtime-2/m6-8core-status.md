# M6 8-Core Cargo Status

更新时间：2026-05-23（Asia/Shanghai）

## 当前结论

已经构建出一个用于 8 核验证的集成内核：

```text
.guest-runs/riscv64-m6/starry-smp8-integration-20260523.bin
.guest-runs/riscv64-m6/starry-smp8-integration-20260523.elf
```

该内核基于最新 `upstream/dev`，叠加了本轮和多核 cargo 路径直接相关的 OS 修复：

- #842：SMP CPU topology 暴露。
- #843：保守版 `riscv_hwprobe`。
- #878：teardown/usercopy/futex 上下文修复。
- #879：RawMutex wakeup owner 语义修复。
- robust futex bad-head tolerance。

## 控制变量

验证尽量保持同一个集成内核、同一个 fsck-clean base rootfs、同一个 host QEMU、同一个 guest cargo workload。当前把“速度 lane”和“正确性 lane”分开记录：

```text
kernel: .guest-runs/riscv64-m6/starry-smp8-integration-20260523.bin
base rootfs: .guest-runs/rootfs-selfbuild-riscv64.img
guest: smp=8
log mode: M6_CARGO_VV=0, no full rustc command lines
```

对照 lane：

```text
j8 speed stress: CARGO_BUILD_JOBS=8, RAYON_NUM_THREADS=8
j4 stability lane: CARGO_BUILD_JOBS=4, RAYON_NUM_THREADS=4
thread=single correctness control: -accel tcg,thread=single
MTTCG speed lane: -accel tcg,thread=multi
```

脚本层改动：

- `scripts/run-m6-starryos-j8-expect.sh` 默认 `snapshot=on`，避免失败运行污染 rootfs。
- 支持 `M6_DRIVE_FORMAT=raw|qcow2`，可以用 qcow2 overlay 持久化结果，不再复制 16G base rootfs。
- guest 内自动把旧 `/opt/build-starry-kernel.sh` 的 `cargo -v` 降为无 `-v`，保留 crate 级进度。
- 增加 `M6_STOP_ON_PANIC=0`，诊断时不在 `panicked at` 处截断 cargo/kernel 输出。
- expect timeout / EOF 会写入 host marker：`===M6-FULL-J8-HOST-TIMEOUT===` 或 `===M6-FULL-J8-HOST-EOF===`，并追加 `[host] expect_rc=...`。

## MTTCG 真并行结果

命令要点：

```text
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=8
RAYON_NUM_THREADS=8
M6_STOP_ON_PANIC=0
```

证据：

```text
log: showtime/multi-cpu/logs/m6-full-smp8-mttcg-j8-integration-panicfull-20260523.log
host qemu CPU: about 400%
riscv_hwprobe spam: 0
full rustc command spam: 0
progress: reached starry-kernel lib, compiled through syn/toml/proc-macro2-diagnostics/syscalls/heck/starry-signal/indoc
failure: rustc processes for syn hit SIGSEGV
```

关键失败：

```text
error: could not compile `syn` (lib)
process didn't exit successfully ... (signal: 11, SIGSEGV: invalid memory reference)
```

这条 lane 证明 QEMU MTTCG 可以让宿主 CPU 并行起来，但当前不能作为 RISC-V guest cargo build 的正确性证明。现象符合已有风险判断：RISC-V TCG MTTCG 对跨 hart LR/SC/原子语义不可靠，真实 Rust/rustc 并行 workload 会暴露用户态崩溃。

## MTTCG j4 稳定性短跑

命令要点：

```text
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=4
RAYON_NUM_THREADS=4
M6_DRIVE_SNAPSHOT=on
M6_QEMU_TIMEOUT_SEC=240
```

证据：

```text
log: showtime/multi-cpu/logs/m6-full-smp8-mttcg-j4-integration-20260523.log
host qemu CPU: about 280% to 370%
progress: core/syn/toml/proc-macro2-diagnostics/lenient_semver/convert_case/once_cell
riscv_hwprobe spam: 0
rseq warning count: 95
SIGSEGV/panic/trap: 0
last heartbeat: guest time about 188s; last rseq line at guest time about 218s
```

这条不是完整编译结果，只是短反馈 smoke。结论是：j4 比 j8 稳定，能形成宿主多线程并行压力，并且在 240s 窗口内没有复现 j8 的 rustc SIGSEGV。它还不能证明完整 M6 已完成。

## MTTCG j4 长跑

当前正式推进的 lane：

```text
log: showtime/multi-cpu/logs/m6-full-smp8-mttcg-j4-overlay-long-20260523.log
rootfs overlay: .guest-runs/rootfs-selfbuild-riscv64-smp8-mttcg-j4-20260523.qcow2
backing rootfs: .guest-runs/rootfs-selfbuild-riscv64.img
drive: format=qcow2, snapshot=off
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=4
RAYON_NUM_THREADS=4
M6_QEMU_TIMEOUT_SEC=14400
```

使用 qcow2 overlay 的原因：保留 guest 编译产物，同时不污染 16G base rootfs，也避免每次复制完整 raw image。若这条完成，下一步从 overlay 中提取 `/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`，再用同一 QEMU 条件做 boot/`ls -la` smoke。

## thread=single 对照

命令要点：

```text
M6_TCG_THREAD=single
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=8
RAYON_NUM_THREADS=8
```

证据：

```text
log: showtime/multi-cpu/logs/m6-full-smp8-single-j8-integration-capture-20260523.log
host qemu CPU: about 100%
riscv_hwprobe spam: 0
full rustc command spam: 0
guest reached about 237s without panic
```

这条 lane 说明同样的 8 guest CPU / j8 workload 在 TCG single 下没有复现 MTTCG 的早期 SIGSEGV，但它不提供宿主并行加速。

## 可汇报说法

这轮已经完成了三件事：

- 真实 8-HART StarryOS kernel 能启动并进入 guest cargo workload。
- #842/#843/#878/#879 等 OS 修复已经让 guest 更接近真实多核 cargo 环境：CPU topology 可见、hwprobe 噪音消失、teardown/usercopy 和 RawMutex 语义更稳。
- 真正使用宿主多线程的 MTTCG 路线目前失败在 rustc SIGSEGV，不能宣称 8 核 cargo build 已正确完成或达到 4x。

下一步不再盲跑 full M6；优先做短反馈：

- 当前先让 MTTCG `smp=8,j4` overlay 长跑；若再次 SIGSEGV 或停滞，再降到 `j2` 找稳定并行上限。
- 抽取一个 Rust/rustc 或用户态原子压力最小复现，区分 QEMU LR/SC 问题和 StarryOS 内核调度/内存问题。
- 若复现指向 OS 行为，再拆成新的 TGOSKit PR；若指向 QEMU MTTCG，则把正确性路线固定为 `thread=single`，加速路线改用真实硬件或架构对齐的虚拟化。
