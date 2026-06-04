# M6 8-Core Cargo Status

更新时间：2026-05-23（Asia/Shanghai）

## 当前结论

### 2026-05-23 04:15 CST 更新

已经基于 #885 的修复内核跑过一轮短反馈：

```text
kernel: .guest-runs/riscv64-m6/starry-smp8-snapshotthread-20260523.bin
rootfs: .guest-runs/rootfs-selfbuild-riscv64.img
QEMU: qemu-system-riscv64 10.2.2 on macOS arm64, -smp 8 -accel tcg,thread=multi
workload: guest 内生成 16 个独立 Rust leaf crate，cargo build --offline --release
```

结果：

```text
jobs=8: 43.59s, PASS
jobs=1: 1m33s, PASS
speedup: 93s / 43.59s = 2.13x
logs:
  过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-snapshotthread-mttcg-j8-leaf16-20260523T040245.log
  过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-snapshotthread-mttcg-j1-leaf16-20260523T040412.log
```

同一内核的 full StarryOS M6 `jobs=8` 已经启动到真实 `starry-kernel` guest cargo 阶段，但没有完成：

```text
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-snapshotthread-mttcg-j8-20260523T040730.log
guest: smp=8, jobs=8, rayon=8
progress: reached [2] cargo build -p starry-kernel (lib), compiling core/syn/toml/syscalls/starry-signal
failure: guest rustc for syn and core exited with signal 11 (SIGSEGV)
kernel panic/trap: none observed in this run
```

这说明 #885 修掉了之前 `fd_ops.rs:269` 的 `kernel task` panic，但 RISC-V QEMU MTTCG 仍不能作为 full cargo correctness lane：full M6 在并行 rustc 下会出现用户态 SIGSEGV。

更宽的 64 leaf synthetic cargo benchmark 也已完成：

```text
jobs=8: 2m47s, PASS
jobs=1: 6m09s, PASS
speedup: 369s / 167s = 2.21x
logs:
  过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-snapshotthread-mttcg-j8-leaf64-20260523T041302.log
  过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-snapshotthread-mttcg-j1-leaf64-20260523T041634.log
```

结论：StarryOS guest 内 `cargo -j8` 的确能并行并带来约 2.1x-2.2x 加速，但在当前 Apple Silicon host 上跑 RISC-V QEMU TCG，full M6 `jobs=8` 仍被 MTTCG correctness 风险卡住；synthetic 宽图也没有达到 4x。`scripts/run-m6-starryos-j8-expect.sh` 和 `scripts/bench-m6-cargo-speed-expect.sh` 已补充 `SIGSEGV` / `signal: 11` 早停匹配，后续不会在 guest rustc 已经崩溃后继续盲等。

当前没有达到 4x 的直接原因：

- 宿主是 macOS arm64，guest 是 riscv64，所有 guest 指令都要经过 QEMU TCG 翻译；`thread=multi` 提供宿主并行，但每个 vCPU 都仍有翻译和同步开销。
- RISC-V MTTCG 在 full cargo workload 下不稳定，`syn` / `core` 的 guest rustc 已经出现 SIGSEGV；因此不能把 MTTCG 当作 full M6 correctness lane。
- full StarryOS M6 早期 cargo graph 不总是 8 路宽；即使 `CARGO_BUILD_JOBS=8`，等待 build-std、proc-macro、链接或文件系统 I/O 时也会退化。
- synthetic leaf64 已足够宽，但每个 crate 较小，进程创建、文件系统元数据、QEMU 设备模拟和串口日志开销会稀释并行收益。

下一条能真正冲 4x 的路线不是继续盲目加 `-j`，而是换正确的加速底座：真实 RISC-V SMP / 正确模拟器，或改用与 Apple Silicon 对齐的 aarch64/HVF guest 路线；RISC-V TCG MTTCG 更适合暴露压力和短基准，不适合作为最终 full M6 PASS 口径。

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

当前不能宣称“完整 M6 已经 8 核编译通过”。已经拿到的是两类更短反馈：

- 速度信号：旧 stable lane 的 synthetic cargo leaf16 在同一个 `smp=8,thread=multi` guest 里，`jobs=1` 为 2m15s，`jobs=8` 为 1m05s，约 2.08x。
- 正确性阻塞：最新 integration / asthreaddiag lane 的 `jobs=8` 会快速复现 `fd_ops.rs:269` 的 `kernel task` panic；已拆出保守 OS hardening draft PR #885，不把它直接包装成 MTTCG correctness 证明。

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
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-mttcg-j8-integration-panicfull-20260523.log
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
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-mttcg-j4-integration-20260523.log
host qemu CPU: about 280% to 370%
progress: core/syn/toml/proc-macro2-diagnostics/lenient_semver/convert_case/once_cell
riscv_hwprobe spam: 0
rseq warning count: 95
SIGSEGV/panic/trap: 0
last heartbeat: guest time about 188s; last rseq line at guest time about 218s
```

这条不是完整编译结果，只是短反馈 smoke。结论是：j4 比 j8 稳定，能形成宿主多线程并行压力，并且在 240s 窗口内没有复现 j8 的 rustc SIGSEGV。它还不能证明完整 M6 已完成。

## MTTCG j4 overlay 长跑

第一轮正式推进的 lane：

```text
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-mttcg-j4-overlay-long-20260523.log
rootfs overlay: .guest-runs/rootfs-selfbuild-riscv64-smp8-mttcg-j4-20260523.qcow2
backing rootfs: .guest-runs/rootfs-selfbuild-riscv64.img
drive: format=qcow2, snapshot=off
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=4
RAYON_NUM_THREADS=4
M6_QEMU_TIMEOUT_SEC=14400
```

结果：

```text
runtime: about 18m41s
host qemu CPU: early about 300%-390%, later about 100%
progress: reached inherit-methods-macro / unicode-xid after darling/yansi
last heartbeat: guest timestamp 2026-05-22T18:44:49Z
last kernel log: rseq at guest time about 727s
SIGSEGV/panic/trap: 0
outcome: stopped manually because log and overlay stopped changing after 02:47:42 CST while QEMU kept one host core busy
```

解释：这不是完成结果，也不是明确 kernel panic。它说明 j4 lane 能早期利用多核，但进入后段后并行度下降到约 1 host core，并且原 heartbeat 不能解释当前 guest 里到底是哪一个 cargo/rustc 进程在跑。

后续 runner 改动：

```text
M6_PROCESS_HEARTBEAT_SEC=30
```

runner 会在 guest 内独立打印 `cargo/rustc/cc/ld/build-starry` 相关进程，避免下一次只看到“QEMU 100% CPU、cargo 没输出”的盲区。

使用 qcow2 overlay 的原因：保留 guest 编译产物，同时不污染 16G base rootfs，也避免每次复制完整 raw image。若后续长跑完成，下一步从 overlay 中提取 `/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`，再用同一 QEMU 条件做 boot/`ls -la` smoke。

## MTTCG j4 overlay 诊断长跑

第二轮加了 process heartbeat 和不截断 panic：

```text
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-mttcg-j4-pshb-20260523.log
rootfs overlay: .guest-runs/rootfs-selfbuild-riscv64-smp8-mttcg-j4-pshb-20260523.qcow2
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=4
RAYON_NUM_THREADS=4
M6_STOP_ON_PANIC=0
```

结果：

```text
progress: 越过上一轮停滞点，继续到 syscalls / strum_macros / ax-config-gen / thiserror-impl
compile failure: ax-config 里 TASK_STACK_SIZE 被旧 rootfs 手工注入 const，与 include_configs! 生成值重复
follow-up panic: sys_openat 读 umask 时 current().as_thread() 命中 kernel task
```

结论：这轮没有证明 M6 完成，但它把问题从“疑似卡住”收敛成两个明确点：

- rootfs/runner 层：旧 rootfs 中残留的 `pub const TASK_STACK_SIZE: usize = 0x20000;` 需要在本轮 runner 里清掉。
- OS 层：kernel task 进入 `sys_openat` 的路径需要 guard/诊断；若能稳定复现，应拆成新的 StarryOS PR，而不是混进脚本修复。

## MTTCG j8 真 8 核当前推进

最新 full M6 j8 lane：

```text
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-mttcg-j8-20260523T031835.log
rootfs overlay: .guest-runs/rootfs-selfbuild-riscv64-smp8-mttcg-j8-20260523T031835.qcow2
M6_TCG_THREAD=multi
M6_QEMU_SMP=8
CARGO_BUILD_JOBS=8
RAYON_NUM_THREADS=8
M6_STOP_ON_PANIC=0
```

已确认：

```text
guest boot: smp=8
guest cargo: jobs=8, rayon=8
runner: 已删除旧 rootfs 注入的 TASK_STACK_SIZE const
progress: ax-config 已越过上一轮重复定义点；当前在 core/syn/syn 早期 build-std/宏 crate 阶段
host observation: QEMU 总 CPU 约 200%，线程级采样显示 2 个 TCG worker 接近满载，其余 hart 基本空闲
```

结果：这条 lane 没有完整通过。约 10 分钟内没有继续增长 crate 级进度，QEMU CPU 长时间维持在约 120%-200%，说明 full M6 早期依赖图没有把 8 个 vCPU 喂满；继续盲等的反馈价值低，已切换到 synthetic cargo 短基准。

## Synthetic Cargo 8 Job 短基准

短基准使用 `scripts/bench-m6-cargo-speed-expect.sh`，不复制 rootfs，不写回 rootfs，QEMU `-snapshot`，只在 guest 内生成一个 16 个 leaf crate 的 offline Rust workspace。它用于快速回答“StarryOS guest 内的 cargo 能否用多 job 获得速度信号”，不是完整 M6 correctness 证明。

已通过的旧 stable lane：

```text
kernel: .guest-runs/riscv64-m6/starry-smp8-stable-*.bin
log j1: 过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-stable-mttcg-j1-leaf16-20260523.log
log j8: 过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-stable-mttcg-j8-leaf16-20260523.log
guest: smp=8, thread=multi, leaves=16
jobs=1: Finished release in 2m 15s
jobs=8: Finished release in 1m 05s
speedup: 135s / 65s = 2.08x
result: PASS / PASS
```

最新 integration/diagnostic lane：

```text
log: 过程记录/早期记录/multi-cpu/logs/cargo-speed-smp8-asthreaddiag-mttcg-j8-leaf16-20260523T033750.log
guest: smp=8, thread=multi, jobs=8, leaves=16
result: 约 13 秒触发 panic
panic marker: M6_AS_THREAD_KERNEL_TASK caller=os/StarryOS/kernel/src/syscall/fs/fd_ops.rs:269:34
```

解释：这说明“8 核 + `cargo -j8` 的启动路径”真实跑到了 StarryOS 多 hart 上，但当前路径仍能暴露 `sys_openat`/umask 上下文使用问题。由于 RISC-V MTTCG 本身有 LR/SC 原子语义风险，这个现象不能直接作为正常硬件上的确定性 OS bug 证明；已按保守 hardening 拆成 draft PR #885：文件创建 syscall 在入口固定用户线程上下文，避免 usercopy 后二次读取 per-CPU current。

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
log: 过程记录/早期记录/multi-cpu/logs/m6-full-smp8-single-j8-integration-capture-20260523.log
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
- 真正使用宿主多线程的 MTTCG 路线已经有 2.08x synthetic cargo 速度信号，但最新集成内核在 `jobs=8` 下复现 `fd_ops.rs:269` kernel-task panic；目前不能宣称完整 M6 已正确完成或达到 4x。该上下文问题已拆成 draft PR #885。

下一步不再盲跑 full M6；优先做短反馈：

- 先等 #885 的 CI 信号；如果通过，再用新内核重跑 synthetic cargo `jobs=1/8`。
- synthetic cargo 重新稳定后，再进入 full M6 j8 overlay。
- 若继续出现 rustc SIGSEGV，再抽取用户态原子/多进程最小复现，区分 QEMU LR/SC 问题和 StarryOS 内核调度/内存问题。
