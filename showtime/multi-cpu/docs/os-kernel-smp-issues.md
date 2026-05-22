# OS Kernel SMP Issues and Fixes

This note records only kernel-level issues found while trying to make
StarryOS build StarryOS inside a multi-HART guest. Docker, rootfs, and QEMU
details are kept as validation context, not as the main result.

## 2026-05-21 Kernel Snapshot

Current kernel-relevant facts:

- 8-HART boot is now verified. OpenSBI reports `Platform HART Count: 8`,
  StarryOS prints `smp = 8`, and a 4G `thread=single` smoke reaches userland
  and exits with `TEST PASSED` / `===MTTCG-BENCH-DONE===`.
- A 6G memory boot hits the bitmap allocator capacity guard before userland:
  `bitmap capacity exceeded: need 1572864 pages but CAP is 1048576`. The
  current workaround is to keep the 8-HART route at `-m 4G`; the kernel issue
  is allocator metadata capacity, not CPU bring-up.
- The futex wait path exposed a real atomic-context bug: `FUTEX_WAIT` rechecked
  the user futex word while holding the wait-queue no-IRQ spinlock, so a normal
  `vm_read()` could try to prepare/populate user memory from atomic context.
  The narrow fix is to keep the first read on the sleepable syscall path and
  use a no-prepare user read only for the locked recheck.
- The raw CPU MTTCG benchmark gives a clean speed signal without cargo/libc:
  at 400M total loop iterations, `thread=single` takes 0.897s / 1.010s for
  4/8 workers, while `thread=multi` takes 0.325s / 0.318s. That is
  2.76x / 3.17x on the 4-HART benchmark line.
- Full M6 is not passed yet. The first 8-HART tmpfs-target lane reached
  `starry-kernel-lib` but hit a cargo build-script `Exec format error`; the
  current main lane moved the target directory back to ext4 and has already
  passed that early failure point while continuing through `starry-kernel-lib`.
- The tmpfs failure now has a smaller OS hypothesis: tmpfs file contents live
  in page cache attached to `DirEntry/Location.user_data`, so cargo-style
  write-then-rename-then-exec may create a final directory entry whose cache
  does not contain the ELF bytes. This should become a focused
  tmpfs rename/readback/exec regression instead of another full M6 rerun.

Fresh evidence:

```text
showtime/multi-cpu/logs/smp8-banner-threadsingle-panic-capture-20260521.log
showtime/multi-cpu/logs/smp8-banner-threadsingle-4g-20260521.log
showtime/multi-cpu/logs/m6-smp8-full-mttcg-j4-futexfix-20260521.log
showtime/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j4-futex-hwprobe-20260521.log
showtime/multi-cpu/logs/m6-smp8-inspect-execformat-mttcg-j2-20260521.log
showtime/multi-cpu/logs/speed-rawcpu-single-smp4-i400m-seq-20260521.log
showtime/multi-cpu/logs/speed-rawcpu-multi-smp4-i400m-seq2-20260521.log
showtime/multi-cpu/benchmarks/raw-cpu-mttcg-20260521.md
```

## Earlier Long Validation Line

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

## K6. waitpid Lost-Wakeup Window Is Real but Not the Whole Exec Fix

Symptom:

- Bash background subshells can report abnormal wait statuses under SMP even
  when the inner command exits successfully.
- A pure C fork/_exit wait stress passes after adding a second status check in
  `sys_waitpid`.
- A stricter C fork+exec `/bin/true` stress still fails later with an
  atomic-context sleep panic in `axtask::WaitQueue::wait_until`.

Kernel cause split:

- Confirmed sub-cause: `sys_waitpid` checked for zombie children, then
  registered a waker. A child exiting in between could produce a lost wakeup.
- Remaining sub-cause: fork+exec under SMP can still leave a task path trying
  to sleep with IRQ disabled and preempt count already zero.

Fix strategy:

- Keep the check/register/check pattern in `sys_waitpid`.
- Do not merge this as the final Bash/fork+exec fix until the fork+exec
  regression also passes.
- Add minimal diagnostics around `TaskInner::join`, `WaitQueue::wait_until`,
  and init task join to identify the actual caller/state owner.

Evidence:

```text
showtime/multi-cpu/logs/waitpid-child-exit-wakeup-fixed-20260520.log
showtime/multi-cpu/logs/waitpid-child-exit-wakeup-exec-waitfix-20260520.log
showtime/multi-cpu/logs/shellcase-function-true-waitfix-20260520.log
```

Regression to add:

- A fork/_exit lost-wakeup regression for the completed sub-fix.
- A fork+exec wait regression that repeatedly execs `/bin/true` from a child
  wrapper and verifies both the wrapper and worker are reaped with status 0.

## K7. Jobs=2 Full Build Can Still Lose Guest Heartbeat in CPU-Heavy Phases

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

## K7. Direct Device I/O and Background Subshell Wait Under SMP

Symptom:

- On the current `origin/dev`-based SMP branch, `SMP=4` boots and a single
  `dd | sha256sum` pipeline completes.
- Two or four concurrent pipelines fail in seconds with:

```text
Segmentation fault (core dumped)
===BENCH-SHA-FAIL rc=1===
```

Evidence:

```text
showtime/multi-cpu/logs/bench-smp4-threadsingle-sha1-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-sha2-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-sha4-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-dd1-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-dd2-20260520.log
showtime/multi-cpu/logs/devzero-full-transfer-fixed-20260520.log
showtime/multi-cpu/logs/shellcase-direct-dd-bg-20260520.log
showtime/multi-cpu/logs/shellcase-function-inner-info-20260520.log
```

Kernel interpretation:

- This split into two OS issues.
- The first issue was direct device I/O: `FileBackend::Direct` transferred only
  one `ax_io::DEFAULT_BUF_SIZE` chunk, so `/dev/zero` and `/dev/null` could
  behave as short 2048-byte operations. The fix is to continue direct
  read/write while the device makes full-chunk progress, stopping on EOF,
  short transfer, or `WouldBlock`.
- The direct I/O fix is validated by `test-dev-zero-full-transfer` and by a
  direct `dd & dd & wait` shell case: both workers return 0.
- The remaining blocker is process wait/exit semantics for nested background
  subshells. In the function/subshell case, both inner `dd` commands return 0
  and the kernel logs the subshell tasks exiting with code 0, but the parent
  Bash `wait` can still report 124.

Regression to add:

- `test-dev-zero-full-transfer`: one large `/dev/zero` read must return the
  full requested length and contain zeros; one large `/dev/null` write must
  return the full requested length.
- A second wait-status regression should model Bash's nested background shape:
  parent starts two intermediate children, each intermediate child starts and
  waits for a worker, then exits 0. The parent must observe both intermediate
  children as exit status 0 under `-smp 4 -accel tcg,thread=single`.

## K8. v22 StoreFault During Early SMP Kernel-Lib Build

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

## K9. Kernel Tasks Appeared in User-Thread Procfs/Wait Paths

Status: fixed in the experiment branch, needs regression design.

Symptom:

- After enabling user interrupt scheduling, one SMP run panicked while reading
  task/process metadata:

```text
panicked at os/StarryOS/kernel/src/task/mod.rs:338:30:
kernel task
```

Kernel cause:

- Under SMP, kernel tasks such as GC or migration tasks can be visible while
  procfs and wait paths walk task IDs.
- Some StarryOS paths used `task.as_thread()` unconditionally, which assumes
  every task is a user thread with StarryOS `Thread` extension data.

Fix strategy:

- Add safe `try_as_thread()` handling in procfs and wait accounting paths.
- Return `NotFound` or skip entries for kernel tasks instead of panicking.

Evidence:

- v25/v26 continued into guest cargo build after procfs/wait paths were made
  kernel-task tolerant.

Regression to add:

- A procfs task walk while per-CPU GC/migration/kernel tasks are active.
- Expected result: user-visible procfs entries remain valid and kernel tasks do
  not crash user-thread-only paths.

## K10. RawMutex Owner Handoff Can Create False Self-Reentry Under SMP

Status: historical fix candidate; superseded by the newer 8-HART futex/exec
findings.

Symptom:

- v26/v27 reached real guest cargo work under:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
```

- v27 failed at the `quote v1.0.45` stage with:

```text
Thread(76) tried to acquire mutex it already owns at os/StarryOS/kernel/src/task/user.rs:38:52
```

- The call site is the user page-fault path:

```text
thr.proc_data.aspace().lock().handle_page_fault(addr, flags)
```

Kernel cause hypothesis:

- `RawMutex::unlock()` handed ownership directly to one waiter by writing that
  waiter's task ID into `owner_id` before the waiter returned from
  `wait_until()`.
- Under SMP scheduling pressure, this leaves an intermediate state where
  `owner_id` names a task that has not actually obtained the guard yet.
- A later page fault by that task can observe `owner_id == current_id` and be
  treated as recursive locking even though the task is not logically inside the
  critical section.

Fix strategy:

- Make unlock conservative:

```text
owner_id.store(0, Release)
notify_one(true)
```

- The woken waiter then competes through the normal CAS path. This trades some
  fairness for a simpler invariant: `owner_id != 0` means the owner has really
  acquired the guard.

Evidence:

- v28 uses the same Linux QEMU container, same fsck-clean rootfs family,
  `-smp 4`, `tcg,thread=single`, `jobs=2`, and only changes the SMP kernel.
- v28 passed the v27 failure point: `quote` build-script completed and the run
  entered `quote` and then `syn v2.0.117` rustc compilation.
- Full PASS was not claimed from this lane. The newer full-M6 line is now
  blocked by the `compiler_builtins` build-script `Exec format error`.

Regression to add:

- A mutex contention stress where several user processes/threads fault pages
  and perform wakeups while a heartbeat task must keep running.
- A smaller kernel-side RawMutex handoff stress if the test framework can
  expose blocking mutexes directly.

## K11. Cargo Parallel Poll Path Can Fault the SMP Kernel

Status: first layer fixed in `/private/tmp/tgoskits-dev-local`.

Symptom:

- With the current diagnostic SMP kernel, a native synthetic cargo smoke
  completes with one cargo job but faults with two cargo jobs:

```text
sha_jobs=1, cargo_jobs=1: PASS, host wall 166s
sha_jobs=1, cargo_jobs=2: FAIL, host wall 47s
```

- The trap is a supervisor write page fault:

```text
Unhandled Supervisor Page Fault @ 0xffffffc08033a122
fault_vaddr=VA:0x40f0b96 (WRITE)
symbol: starry_kernel::syscall::io_mpx::poll::do_poll::{closure...}
```

Kernel interpretation:

- This is now a direct cargo parallelism correctness blocker. The corrected
  harness passes `M6_BENCH_CARGO_JOBS=2` through to `cargo build -j2`, and the
  crash appears after cargo starts compiling two independent synthetic leaf
  crates.
- It is also not the old direct `/dev/zero` short-transfer bug: the two direct
  dd workers finish and report exit code 0.
- The mapped instruction is the `pollfd.revents` update in
  `syscall/io_mpx/poll.rs`. Because that write goes to a low user address from
  supervisor mode, the suspicious area is the `poll_fds` / `revent_indices`
  state captured across `block_on(poll_io(...))`, plus pipe/jobserver wakeups
  used by cargo/rustc.
- The earlier two-worker background dd then cargo `rc=139` failure remains
  useful as a broader process/exec stress shape, but `cargo_jobs=2` is now the
  smaller primary reproduction.

Fix:

- `sys_poll` and `sys_ppoll` no longer expose the user `pollfd` array as a
  mutable kernel slice across `block_on(poll_io(...))`.
- The syscall now copies `pollfd` entries into a kernel `Vec`, records the
  indices that correspond to valid fds, updates the kernel copy in the polling
  closure, and writes `revents` back to user memory after the blocking operation
  returns.
- This keeps faultable user-memory writes in the explicit syscall copy-out path
  instead of inside the async poll callback.

Evidence:

```text
showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j1-pass-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j2-fail-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-fail-20260520.log
showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-pass-20260520.log
```

Regression to add:

- Added `test-suit/starryos/normal/test-ppoll-user-buffer` in the dev-local
  branch. It blocks in `ppoll` on a pipe, wakes from a child write, and checks
  that `POLLIN` is copied back to the user `revents` field.

Validation:

```text
SMP=4, TCG=single, synthetic native cargo
sha_jobs=1, cargo_jobs=2, foreground cargo: PASS
host wall 195s
===BENCH-CARGO t0=0 t1=0 exit=0 jobs=2 sha_jobs=1===
===BENCH-DONE===
```

Remaining follow-up:

- Background cargo with heartbeat reaches Cargo's own `Finished` line but
  misses the benchmark completion marker after `wait "$cargo_pid"`. That is now
  tracked separately as a wait/exit-status cleanup issue.

## K12. 8-HART Bring-up Exposed a Bitmap Allocator Capacity Limit

Status: boot workaround validated; kernel allocator fix still open.

Symptom:

- A StarryOS build configured for 8 HARTs starts correctly under OpenSBI and
  reaches the StarryOS banner.
- With a 6G guest memory layout it panics immediately in the physical-page
  bitmap allocator:

```text
smp = 8
panicked at components/axallocator/src/bitmap.rs:80:9:
bitmap capacity exceeded: need 1572864 pages but CAP is 1048576
```

Kernel interpretation:

- `1572864` 4K pages is 6 GiB, while `1048576` pages is 4 GiB.
- This is not a scheduler or secondary-HART start failure. The kernel is
  trying to describe more managed physical pages than the fixed bitmap
  allocator capacity allows.

Current workaround:

- Run the 8-HART validation lane with `-m 4G`.
- Under `-smp 8 -m 4G -accel tcg,thread=single`, StarryOS prints `smp = 8`,
  reaches userland, and the smoke exits with `TEST PASSED`.

PR-sized fix direction:

- Make the allocator capacity derive from the platform memory layout or use a
  dynamically sized metadata region.
- Add a boot-time regression for `riscv64-qemu-virt` with memory above 4G so
  the failure is caught as an allocator/config limit instead of during M6.

Evidence:

```text
showtime/multi-cpu/logs/smp8-banner-threadsingle-panic-capture-20260521.log
showtime/multi-cpu/logs/smp8-banner-threadsingle-4g-20260521.log
```

## K13. Futex Wait Recheck Must Not Prepare User Memory in Atomic Context

Status: narrow fix candidate identified; regression prepared.

Symptom:

- In the 8-HART full-path smoke, many rustc/ctrl-c tasks hit:

```text
prepare_user_memory will lock aspace in atomic context:
syscall=Some(futex) access_flags=READ irq_enabled=false preempt_count=1
```

- The old path can then panic after the futex wait queue enters a no-IRQ
  critical section.

Kernel cause:

- `FUTEX_WAIT` needs an atomic check/enqueue/recheck shape to avoid lost
  wakeups.
- The initial user futex read is safe on the normal syscall path, but the
  second recheck runs under the wait-queue `SpinNoIrq` lock.
- Calling the normal `uaddr.vm_read()` there can populate user pages and take
  the address-space mutex, which is illegal in atomic context.

Fix strategy:

- Keep the first `uaddr.vm_read()? != value` check before taking the futex wait
  lock.
- For the locked recheck only, use `vm_read_u32_noprepare(uaddr)`: validate the
  address range and copy the already-present 32-bit word with `user_copy`, but
  do not fault in pages or take the address-space lock.
- Keep this helper narrow to futex recheck semantics; broad no-prepare user
  access would hide real page-fault requirements elsewhere.

Regression to add:

- `bug-futex-wait-wake`: a pthread waits with `FUTEX_WAIT|PRIVATE`, another
  thread stores the new value and wakes it, and the waiter must return 0
  without an atomic user-memory warning or panic.

Evidence:

```text
showtime/multi-cpu/logs/m6-smp8-fullpath-expect-smoke-mttcg-j4-20260521.log
test-suit/starryos/normal/qemu-smp1/bugfix/bug-futex-wait-wake
```

## K14. Raw CPU MTTCG Speed Signal Is Real but Not a Correctness Proof

Status: benchmark evidence captured; use only as speed signal.

Controlled workload:

- Kernel: `.guest-runs/riscv64-m6-bench/starry-platformdiag-signalframe-20260521.bin`
- QEMU: `-smp 4 -m 4G`
- Only variable: `-accel tcg,thread=single` vs `-accel tcg,thread=multi`
- Workload: raw syscall benchmark using `write`, `clock_gettime`, `clone`,
  `wait4`, and `exit`, with 400M total loop iterations.

Results:

| workers | single TCG us | multi TCG us | speedup |
| --- | ---: | ---: | ---: |
| 1 | 864544 | 778779 | 1.11x |
| 2 | 881604 | 541909 | 1.63x |
| 4 | 897394 | 325329 | 2.76x |
| 8 | 1010162 | 318373 | 3.17x |

Kernel interpretation:

- This proves QEMU MTTCG can give the guest visible CPU parallelism on a
  syscall-minimal workload.
- It also gives a cheap regression lane for scheduler, `clone`, and `wait4`
  changes.
- It is not a correctness proof for Rust/Cargo or futex-heavy workloads because
  RISC-V MTTCG still has LR/SC modeling risk. The tmpfs full-M6 lane exposed a
  separate build-script execution failure; the ext4 lane is the active cargo
  validation route.

Evidence:

```text
showtime/multi-cpu/logs/speed-rawcpu-single-smp4-i400m-seq-20260521.log
showtime/multi-cpu/logs/speed-rawcpu-multi-smp4-i400m-seq2-20260521.log
showtime/multi-cpu/logs/speed-rawcpu-multi-smp4-i400m-ioctlfix-20260521.log
showtime/multi-cpu/logs/test-ioctl-usercopy-locks-multi-smp4-20260521.log
showtime/multi-cpu/benchmarks/raw-cpu-mttcg-20260521.md
```

## K15. Tmpfs Target Can Produce Build-Script Exec Format Error

Status: open; do not claim final M6 PASS from the tmpfs lane. The ext4 lane is
currently the primary full-M6 route.

Symptom:

- The 8-HART tmpfs-target full run boots with `smp = 8`, starts the full
  selfbuild, and enters `starry-kernel-lib`.
- The run requests `CARGO_BUILD_JOBS=4` / `RAYON_NUM_THREADS=4`, while the
  guest parallelism line still reports `nproc=2`; user-space CPU topology
  exposure remains a separate OS cleanup item.
- Cargo begins compiling `compiler_builtins`, `core`, `proc-macro2`, `quote`,
  and `unicode-ident`, then fails:

```text
error: failed to run custom build command for `compiler_builtins v0.1.160`
could not execute process `/opt/tgoskits/.m6-work/target/release/build/compiler_builtins-.../build-script-build` (never executed)
Exec format error (os error 8)
```

Kernel-facing interpretation:

- The strongest current hypothesis is tmpfs readback/cache identity across
  cargo's write-temporary-then-rename pattern. Tmpfs stores ordinary file bytes
  in page cache while the tmpfs inode metadata mainly tracks length; if the
  cache is keyed by a directory-entry location rather than a stable inode, the
  final renamed path can have a valid size but read zero/non-ELF bytes.
- `load_elf` is likely the reporter, not the root cause: it reads the first
  page, fails ELF validation, and returns ENOEXEC to user space.
- This is materially different from a successful M6 marker. There is no
  `===M6-SELFBUILD-PASS===` or guest-built kernel boot-smoke evidence on this
  lane yet. The ext4 target run exists to continue cargo validation while this
  tmpfs path is reduced.

Short feedback loop:

- Add a tmpfs regression that copies a known ELF to `/tmp/.tmp-exe`, closes it,
  renames it to `/tmp/final-exe`, verifies the final ELF magic, then `fork` +
  `execve`s it. Repeat and run several workers to mimic cargo J4.
- If the failed tmpfs guest is still alive, inspect the final build script with
  `stat`, `od -An -tx1 -N16`, and direct execution. A normal size with a zero or
  non-ELF header confirms tmpfs readback/cache identity rather than toolchain
  output format.
- Keep ext4 as the main long full-M6 route until the focused tmpfs regression
  explains this failure.

Evidence:

```text
showtime/multi-cpu/logs/m6-smp8-full-mttcg-j4-futexfix-20260521.log
showtime/multi-cpu/logs/m6-smp8-inspect-execformat-mttcg-j2-20260521.log
showtime/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j4-futex-hwprobe-20260521.log
```

## Next Fast Feedback Experiments

1. Keep the 8-HART boot lane at `-m 4G` until the bitmap allocator capacity
   issue has a real kernel fix.
2. Use ext4 target for the current full self-build lane; reduce the tmpfs
   `compiler_builtins` build-script `Exec format error` with a smaller
   tmpfs rename/readback/exec regression.
3. Use subset or early-pressure runs for concurrency exploration; do not run
   two memory-heavy full selfbuilds unless the host has enough headroom.
4. `SMP=4 + thread=single + jobs=2` subset has passed. The current `jobs=2`
   full-pressure line has moved from v22 StoreFault to v27/v28 mutex handoff
   validation, and the 8-HART line has moved to futex/exec validation.
5. Preserve the exact panic/error and reduce it to one OS regression before
   raising cargo parallelism further.
6. Keep `thread=multi` as a speed-only experiment because RISC-V MTTCG is not a
   correctness proof for atomic-heavy workloads.
