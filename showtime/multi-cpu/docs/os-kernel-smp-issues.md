# OS Kernel SMP Issues and Fixes

This note records only kernel-level issues found while trying to make
StarryOS build StarryOS inside a multi-HART guest. Docker, rootfs, and QEMU
details are kept as validation context, not as the main result.

## Current Validation Line

- date: 2026-05-18
- run: `m6-smp4-threadsingle-j1-full-v19-user-timer-yield`
- purpose: prove that an SMP StarryOS kernel can sustain a real guest
  StarryOS self-build before enabling higher cargo parallelism.
- configuration:
  - guest kernel: `smp = 4`
  - QEMU TCG: `thread=single`
  - cargo jobs: `CARGO_BUILD_JOBS=1`
  - rayon threads: `RAYON_NUM_THREADS=1`
  - rebuild policy: force rebuild StarryOS/kernel artifacts after checkpoint
    restore.
- high-signal evidence:
  - boot log shows `smp = 4`.
  - build log shows `force rebuild requested: bypass kernel rlib resume`.
  - guest heartbeat continues during long CPU-bound rustc phases.
  - the run has passed the previous `thiserror v2.0.18` observation point.
  - the run later reached `ax-task`, `ax-driver`, `hashbrown`, and related
    crates before the host killed QEMU.

This run is a correctness run, not a speed run. It validates SMP scheduler,
user task affinity, process, filesystem, and timer paths under a long
real-world workload. It is not a final PASS proof because the host killed QEMU
before the guest build marker and phase2 smoke.

## K1. User Timer Interrupt Did Not Create a Scheduler Opportunity

Symptom:

- During a long `rustc` phase, QEMU stayed alive and consumed CPU, but guest
  progress messages could stop for a long time.
- This made it hard to distinguish real work from a scheduler stall.

Kernel cause:

- StarryOS runs user code through `uctx.run()`.
- When a timer interrupt returned as `ReturnReason::Interrupt`, the user loop
  continued without an explicit scheduler handoff.
- A CPU-bound user process could therefore monopolize its run queue until a
  syscall, fault, or another blocking point.

Fix strategy:

- In the user return loop, handle `ReturnReason::Interrupt` by calling
  `ax_task::yield_now()`.
- This turns timer preemption into an explicit scheduling point for
  CPU-bound user code.

Evidence:

- In v19, guest heartbeats keep appearing during long phases such as `core`,
  `syn`, `thiserror`, and later kernel dependency crates.
- v19 has passed the earlier v18 observation point around
  `thiserror v2.0.18`.

Regression to add:

- A CPU-bound user workload plus a periodic heartbeat or peer task.
- Expected result: the peer task continues to run under SMP, even if the
  CPU-bound task does not enter syscalls frequently.

## K2. User Tasks Are Not Yet Fully Cross-CPU Migration Safe

Symptom:

- When blocked tasks were allowed to wake on a different CPU for load balance,
  one run panicked in a syscall path because `current().as_thread()` observed
  the wrong task shape.

Kernel cause:

- StarryOS user tasks carry thread/process context through `TaskExt`.
- Some syscall and user-thread paths still assume the task wakes and resumes
  with the expected StarryOS user context on its previous CPU.
- Therefore, arbitrary cross-CPU wakeup for user tasks is not safe yet.

Fix strategy:

- Pin a task to the current CPU while it is executing user mode.
- When a blocked task has StarryOS user `TaskExt`, wake it on its previous CPU
  for now.
- Allow plain kernel tasks without user context to use load-based run queue
  selection.

Evidence:

- The v17 cross-CPU wakeup panic is not reproduced in v19 after restoring user
  task wake affinity.
- Long guest cargo phases continue to make progress under `smp = 4`.

Regression to add:

- A user task blocks in a syscall, is woken while several CPUs are active, and
  then immediately performs another syscall requiring `current().as_thread()`.
- Expected result: the current task still has valid StarryOS user-thread
  context.

## K3. Run Queue Selection Needed Load Visibility

Symptom:

- Early SMP experiments had no clear kernel-side signal explaining why a task
  should be placed on one CPU rather than another.
- This made it risky to increase user parallelism because load balancing and
  user affinity were mixed together.

Kernel cause:

- Run queues did not expose a lightweight per-CPU runnable load signal for
  placement decisions.
- User tasks and kernel tasks need different policies while user migration is
  still conservative.

Fix strategy:

- Track per-CPU run queue load.
- Use load selection for non-pinned kernel tasks.
- Keep user tasks affinity-first until user thread migration is made safe.

Evidence:

- The current kernel can distinguish migration-pinned/user tasks from plain
  kernel tasks.
- This creates a safer base for the next `jobs=2` and `jobs=4` experiments.

Regression to add:

- Kernel-worker wakeup/load-balance test that does not involve StarryOS user
  `TaskExt`.
- Separate user-task affinity regression so these two policies are not tested
  as one mixed behavior.

## K4. Diagnostics Needed to Point Back to Kernel Call Sites

Symptom:

- Multi-hour QEMU runs can fail late, and the last panic line alone may not
  show which kernel path created an invalid preempt/block state.

Fix strategy:

- Add `track_caller`-based diagnostics around preempt/blocking paths.
- Record the call site that disabled preemption or entered a blocked
  reschedule path.

Evidence:

- Later runs can report a more useful kernel call site instead of only the
  final panic location.

Regression to add:

- Keep this as diagnostic infrastructure; it should not be the behavioral PR by
  itself unless paired with a concrete scheduler bug.

## K5. Early Kernel-Lib Build Did Not Compile SMP Scheduler Paths

Symptom:

- The guest self-build first runs `cargo build -p starry-kernel` before the
  final `starryos --features starryos/qemu,smp` passes.
- Because `starry-kernel` had no `smp` feature, that early lib stage did not
  enable `ax-feat/smp`.
- As a result, SMP-only run queue code was not covered until the later full
  `starryos` pass, which makes feedback much slower.

Kernel cause:

- `starryos` defines `smp = ["ax-feat/smp", ...]`, but `starry-kernel` did not
  expose a matching feature.
- The self-build script already knows how to pass `--features smp` to
  `starry-kernel` when such a feature exists.

Fix strategy:

- Add `smp = ["ax-feat/smp"]` to `os/StarryOS/kernel/Cargo.toml`.
- This lets the earlier `starry-kernel` lib build compile `ax-task/smp` and run
  queue SMP paths directly.

Expected validation:

- The next injected run should print:

```text
[2] starry-kernel: enabling workspace feature smp (matches baked axconfig SMP)
```

- The `effective_cpumask` / `is_migration_pinned` unused warning should
  disappear in an SMP lib-stage build because `run_queue.rs` uses those helpers
  behind `cfg(feature = "smp")`.

Host-side validation:

```text
RUSTUP_TOOLCHAIN=nightly-2026-04-01-aarch64-apple-darwin CARGO_NET_OFFLINE=true \
cargo check -p starry-kernel --target riscv64gc-unknown-none-elf --features smp --release
```

Result:

```text
Finished `release` profile [optimized] target(s) in 22.16s
```

## K6. Jobs=2 Full Build Can Still Lose Guest Heartbeat in CPU-Heavy Phases

Symptom:

- v21 (`SMP=4`, `thread=single`, `jobs=2`) reached a real cargo build and
  showed concurrent crate starts: `core`, `proc-macro2`, `quote`, then
  `syn v2.0.117`.
- Guest heartbeat continued until `2026-05-18T07:23:29Z`.
- After that, the serial log stopped growing for 3600 seconds and the host
  stall detector killed QEMU.
- No guest panic, SIGSEGV, or Rust compile error was captured.

Interpretation:

- This is different from a kernel crash: QEMU was still alive from the host
  view, but the guest stopped producing observable progress.
- It may be a false-positive stall during an extremely slow `syn` build, but
  for an OS validation workload it still indicates poor responsiveness: the
  heartbeat process could not get enough CPU or I/O progress to report.

OS hypothesis:

- With `jobs=2`, two CPU-heavy user processes can occupy run queues in a way
  that still starves lightweight progress tasks.
- The timer-yield fix improved `jobs=1`, but `jobs=2` needs a smaller
  scheduler regression to verify cross-runqueue fairness and wakeup behavior.

Next validation:

- Re-run with `starry-kernel/smp` enabled in the early lib stage so SMP run
  queue code is compiled earlier.
- Use a longer stall threshold once to determine whether `syn` eventually
  completes.
- If heartbeat still disappears for a long window, reduce to a CPU-bound
  two-process workload plus a heartbeat task.

## K7. v22 StoreFault During Early SMP Kernel-Lib Build

Status: open.

Latest evidence:

- v22 enabled `starry-kernel/smp` in the early guest lib build.
- The run kept heartbeat alive through several crates after the previous v21
  stall point.
- It then panicked in the kernel with:

```text
Unhandled trap Exception(StoreFault) @ 0xffffffc0803f0bbc, stval=0xffffffc1c0001000
```

Interpretation:

- This is useful evidence that the short feedback loop is now reaching a
  concrete OS fault instead of only timing out.
- The fault should be reduced before claiming full multi-core M6 success.
- Likely isolation directions are page-table/TLB handling, allocator metadata,
  or task-context corruption under `SMP=4 + jobs=2`.

## Next Fast Feedback Experiments

1. Use one full self-build as the hard correctness proof for `smp = 4`.
2. Use subset or early-pressure runs for concurrency exploration; do not run
   two memory-heavy full selfbuilds unless the host has enough headroom.
3. `SMP=4 + thread=single + jobs=2` subset has passed. The current next signal
   is reducing the v22 StoreFault into a smaller OS regression.
4. Preserve the exact panic/error and reduce it to one OS regression before
   raising cargo parallelism further.
5. Keep `thread=multi` as a speed-only experiment because RISC-V MTTCG is not a
   correctness proof for atomic-heavy workloads.
