# Multi CPU Progress Log

## 已完成

1. 明确目标不是“多核串行”，而是 guest build 能真实并行加速。
2. 在小型 hello-world cargo workspace 上观察到速度提升：
   - `-j1`: 约 176s
   - `-j4`: 约 62s
3. 尝试了 SMP4 kernel 实验版本。
4. 初步定位多核版本需要关注 futex/private flag 和 mutex unlock/wakeup 语义。
5. 尝试了完整 M6 `-smp 4 -accel tcg,thread=multi CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4` 路线，13 秒内失败，形成短反馈日志。
6. 形成内核实现问题记录：
   - `showtime/multi-cpu/docs/os-kernel-smp-issues.md`
   - 重点只记录 OS 层问题：用户态 timer 抢占、用户任务迁移亲和性、run queue load 和诊断 callsite。

## 当前实验改动

| area | file | change | status |
| --- | --- | --- | --- |
| futex | `os/StarryOS/kernel/src/syscall/sync/futex.rs` | 支持 `FUTEX_PRIVATE_FLAG` | 实验中 |
| mutex | `os/arceos/modules/axsync/src/mutex.rs` | unlock 先释放 owner/state，再 wake waiter | 实验中 |
| user scheduling | `os/StarryOS/kernel/src/task/user.rs` | 用户态 timer interrupt 返回后显式 `yield_now()`；用户态运行期间 pin 当前 CPU | v19 验证中 |
| scheduler | `os/arceos/modules/axtask/src/task.rs`, `run_queue.rs` | 记录 migration pin 和 run queue load；用户任务 blocked wake 保持亲和性，kernel task 可按负载分配 | v19 验证中 |
| diagnostics | `os/arceos/modules/axtask/src/task.rs`, `run_queue.rs` | 为 preempt/block 路径增加 `track_caller` 线索 | 已用于后续定位 |
| feature wiring | `os/StarryOS/kernel/Cargo.toml` | 新增 `smp = ["ax-feat/smp"]`，让早期 `starry-kernel` lib 阶段也编译 SMP 调度路径 | 待下一轮注入验证 |

Feature wiring static validation:

```text
RUSTUP_TOOLCHAIN=nightly-2026-04-01-aarch64-apple-darwin \
CARGO_NET_OFFLINE=true \
cargo check -p starry-kernel --target riscv64gc-unknown-none-elf --features smp --release
```

Result:

```text
Finished `release` profile [optimized] target(s) in 22.16s
```

Interpretation:

- The new `starry-kernel/smp` feature resolves offline.
- The check reaches `ax-task`, `ax-sync`, `ax-runtime`, and `ax-feat` with SMP
  enabled, so the early kernel-lib stage can now cover SMP scheduler code in
  the next guest-injected run.

## 2026-05-18 v19 SMP4 correctness run

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 M6_FORCE_REBUILD_KERNEL=1
```

Purpose:

- This is not the final speed run.
- It proves that a 4-HART StarryOS kernel can sustain a real guest StarryOS
  self-build after the scheduler/user-affinity fixes.

High-signal evidence so far:

```text
smp = 4
parallelism: mode=multi-vcpu nproc=4 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1
force rebuild requested: bypass kernel rlib resume
```

Current status:

- The run ended without PASS after 16887 seconds.
- Host side reported the QEMU process as `Killed`.
- There was no guest panic in the captured log.
- Guest heartbeat was still being emitted during long `rustc` phases up to the
  end.
- It has passed the earlier observation point around `thiserror v2.0.18`.
- Latest observed crates include `ax-task`, `ax-driver`, `hashbrown`, and
  allocator-related crates.

Interpretation:

- The user-mode timer-yield change is doing what it was meant to do: long
  CPU-bound guest code no longer removes observability from the system.
- The conservative user-task affinity policy avoided the previous cross-CPU
  wake panic.
- This run is not a full PASS proof. It ended because the host killed QEMU,
  most likely from resource pressure after running concurrent experiments.
- Full PASS still requires a later final guest build marker and phase2 smoke.

## 2026-05-18 v20 SMP4 jobs=2 subset smoke

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2 --subset
```

Purpose:

- Run concurrently with v19 to get a faster signal.
- This is a light smoke, not a full self-build.
- It checks that the new SMP kernel boots with 4 HARTs, exposes `nproc=4`,
  accepts `jobs=2`, and can run guest cargo metadata/pkgid paths without
  immediately tripping scheduler, process, or filesystem bugs.

Evidence files:

```text
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-subset-v20-user-timer-yield.log
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-subset-v20-user-timer-yield.progress.csv
```

Result:

```text
PASS
```

Observed marker:

```text
===M6-SELFBUILD-SUBSET-PASS===
```

High-signal lines:

```text
smp = 4
parallelism: mode=multi-vcpu nproc=4 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
metadata exit=0
riscv-h pkgid exit=0
ax-cpu pkgid exit=0
ax-errno pkgid exit=0
```

Interpretation rules:

- This passed, so the next useful fast-feedback step is a heavier `jobs=2`
  full-build early-pressure run on a separate rootfs image.
- If this fails, preserve the first panic/error and reduce it to an OS-level
  regression before trying full `jobs=2`.

## 2026-05-18 v21 SMP4 jobs=2 full early-pressure run

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2 M6_FORCE_REBUILD_KERNEL=1
```

Purpose:

- Run in parallel after v20 subset passed.
- Use a separate rootfs image so it does not race with the v19 correctness
  rootfs.
- Get an earlier signal for user parallelism pressure while v19 continues the
  conservative full correctness run.

Evidence files:

```text
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v21-user-timer-yield-early.log
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v21-user-timer-yield-early.progress.csv
```

High-signal evidence so far:

```text
Platform HART Count       : 4
smp = 4
host plan: qemu_vcpus=4 tcg_thread=single cargo_jobs=2 rayon_threads=2
parallelism: mode=multi-vcpu nproc=4 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
force rebuild requested: bypass kernel rlib resume
[2] start cargo build -p starry-kernel (lib)
heartbeat phase=starry-kernel-lib
```

Validation context:

- The selected old full-run rootfs had one ext4 directory checksum issue during
  pre-inject fsck. `e2fsck` repaired it before QEMU boot.
- Treat that as rootfs hygiene for this experiment, not as an OS kernel PR
  conclusion.

Interpretation rules:

- If v21 fails before or during early cargo phases, use its first panic/error
  as the next OS-level regression target.
- If v21 reaches long rustc phases with heartbeat alive, that strengthens the
  timer-yield and user-affinity fixes under higher user parallelism.
- v21 does not replace v19 unless it reaches the final full build marker.

Live status:

- v21 ended without PASS.
- Host-side stall detector stopped QEMU after 8959 seconds because the serial
  log had no new bytes for 3600 seconds.
- No guest panic, SIGSEGV, or Rust compile error was captured.
- It entered the starry-kernel lib build and is emitting guest heartbeat.
- It has shown concurrent cargo starts such as `core`, `proc-macro2`, and
  `quote`, which confirms `jobs=2` is applying user-level parallelism.
- It has reached `syn v2.0.117` with heartbeat still alive.
- After `syn v2.0.117`, the last guest heartbeat was
  `2026-05-18T07:23:29Z`; no later serial output arrived before the stall kill.
- This is now an OS responsiveness/scheduler feedback issue to reduce: under
  `jobs=2`, a CPU-heavy rustc/proc-macro phase can still make the heartbeat
  disappear for too long.

Next action:

- Start v22 with the new `starry-kernel/smp` feature wiring so the early
  `starry-kernel` lib stage directly compiles SMP scheduler paths.
- Increase the stall threshold to distinguish a very slow `syn` build from a
  true scheduler starvation.

## 2026-05-18 v22 SMP4 jobs=2 full with kernel SMP feature

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2 M6_FORCE_REBUILD_KERNEL=1 M6_STALL_SEC=7200
```

Purpose:

- Re-run the `jobs=2` full early-pressure path after adding
  `starry-kernel/smp`.
- Validate that the early `[2] starry-kernel` lib stage now directly compiles
  SMP scheduler code instead of waiting for later `starryos --features smp`
  passes.
- Use a longer stall threshold once, because v21 might have killed a very slow
  `syn` phase before it recovered.

Evidence files:

```text
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v22-kernel-smp-feature.log
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v22-kernel-smp-feature.progress.csv
```

Expected early marker:

```text
[2] starry-kernel: enabling workspace feature smp (matches baked axconfig SMP)
```

Observed early marker:

```text
smp = 4
parallelism: mode=multi-vcpu nproc=4 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
[2] starry-kernel: enabling workspace feature smp (matches baked axconfig SMP)
[2] cargo build --offline -p starry-kernel (lib) --features smp
```

Result:

- v22 did not reach PASS.
- It continued past the feature marker and kept guest heartbeat alive through
  crates such as `strum_macros`, `ax-errno`, `ax-crate-interface`, and
  `syn v1.0.109`.
- It then hit a kernel trap:

```text
Unhandled trap Exception(StoreFault) @ 0xffffffc0803f0bbc, stval=0xffffffc1c0001000
```

Interpretation:

- The new feature wiring is active inside the guest.
- The early kernel-lib stage now covers SMP scheduler code.
- The next blocker is no longer "does early SMP feature wiring work"; it is a
  concrete OS/kernel memory or scheduling fault under `SMP=4 + jobs=2`
  pressure.

## 2026-05-19 v23-v28 SMP4 jobs=2 full-pressure line

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2 M6_FAST_FEEDBACK=1
```

Purpose:

- Continue from a clean upstream-dev-based TGOSKit worktree.
- Keep QEMU in `tcg,thread=single` for correctness, so any failure is more
  likely a StarryOS kernel issue than QEMU MTTCG LR/SC emulation.
- Reuse checkpointed rootfs state for a short feedback loop, then change only
  the kernel between diagnostic runs.

Evidence files:

```text
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v26-resched-if-needed.log
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v27-mutex-caller.log
showtime/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v28-mutex-unlock-competitive.log
```

High-signal sequence:

1. v23 reached userland but hit a `kernel task` panic in a user-thread-only
   path.
2. procfs/wait accounting was made tolerant of kernel tasks by using
   `try_as_thread()`.
3. v26 used `ax_task::resched_if_needed()` instead of unconditional timer
   `yield_now()` and reached `quote v1.0.45`, then panicked in `RawMutex`.
4. v27 added `track_caller` to `RawMutex` and identified the caller:

```text
Thread(76) tried to acquire mutex it already owns at os/StarryOS/kernel/src/task/user.rs:38:52
```

5. The call site is the user page-fault path acquiring the process address-space
   mutex.
6. v28 changed `RawMutex::unlock()` from direct owner handoff to conservative
   unlock-then-wake:

```text
owner_id.store(0, Release)
notify_one(true)
```

Live result:

- v28 has passed the v27 failure point.
- It completed the `quote` build-script, entered `quote` rustc, and continued
  into `syn v2.0.117`.
- It then continued through later bare-metal/kernel dependency phases including
  `compiler_builtins`, `alloc`, `ax-kspin`, `ax-config-gen`,
  `critical-section`, `riscv-types`, `embedded-hal`, and `riscv v0.16.0`.
- It later reached `ax-percpu`, `heapless`, `toml`, `ax-allocator`,
  `ax-hal`, `ax-plat`, `ax-page-table-multiarch`, `darling_core`, and
  `futures-util`.
- At the latest observation (`2026-05-19 19:53 CST`), Docker still had the
  v28 container up, QEMU was using about one host CPU, and memory usage was
  about 4.8 GiB.
- However, the guest serial log stopped growing after the heartbeat at
  `2026-05-19T10:12:57Z`; the progress monitor still reports the same
  `log_bytes=500192` and `log_lines=3041` at elapsed `13986s`.
- The run is still being monitored; this is not a full PASS claim yet. If no
  new serial bytes arrive before the stall threshold, treat this as the next
  OS responsiveness/scheduler feedback issue rather than as a Docker build
  success.

Interpretation:

- The current leading root cause is `RawMutex` owner handoff under SMP
  contention, not a Docker/script issue.
- The smaller OS regression should stress blocking mutex wakeup plus page-fault
  allocation or address-space locking.

## 当前产物位置

尚未复制到 showtime artifact 目录。实验产物仍在：

- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.bin`
- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.elf`

## 还没有完成

- 多轮 benchmark。
- M6 级别 guest cargo build 的稳定加速验证；当前 `SMP=4 + thread=single + jobs=2`
  已经越过 v27 的 `quote` mutex panic，并推进到 `riscv v0.16.0` 一带，v28
  仍在运行中。
- 对每个 kernel fix 单独拆测例。
- 判断哪些实验改动适合 PR。
- 在 host Linux 和 guest Starry QEMU 两种环境分别跑完整日志。

## 2026-05-18 SMP4 MTTCG full M6 attempt

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=multi CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 M6_RESUME=0
```

Result:

```text
rc=1 elapsed_sec=13
```

Evidence:

```text
showtime/multi-cpu/logs/m6-smp4-mttcg-j4.log
showtime/multi-cpu/logs/m6-smp4-mttcg-j4.done
```

High-signal lines:

```text
smp = 4
===GUEST_ONECRATE_INIT_DIRECT===
M6 work dirs: tmpfs=1 CARGO_HOME=/opt/tgoskits/.m6-work/cargo-home CARGO_TARGET_DIR=/opt/tgoskits/.m6-work/target
panicked at .../library/alloc/src/alloc.rs:573:9:
memory allocation of 8912904 bytes failed
```

Interpretation:

- This is a real multi-vCPU run, but it is an MTTCG speed experiment, not a correctness proof.
- It did not reach full cargo compilation; it failed during early guest init/toolchain setup.
- Next shortest isolation is to run the same 4-vCPU/cargo-j4 workload with `M6_TCG_THREAD=single` and preferably `--subset` first. If that also fails, the issue is likely StarryOS SMP/kernel memory pressure rather than MTTCG only. If it passes, the MTTCG/LR-SC risk becomes the leading suspect.
