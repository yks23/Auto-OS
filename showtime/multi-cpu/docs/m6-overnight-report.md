# M6 Overnight Report

## Goal

Make the StarryOS guest build StarryOS under an SMP kernel, then use the result
to drive OS-level fixes and PRs.

## Current Rule

- Confirmed OS bug: reduce it, fix it in TGOSKit, add a focused test-suite
  case, and prepare a PR against `dev`.
- Feedback loop longer than 2 hours: shorten the loop before rerunning the same
  long path.
- No concrete bug: add high-signal logs before another long run.

## Current Run

Configuration:

```text
host qemu-system-riscv64, launched through expect for command injection
kernel .guest-runs/riscv64-m6-bench/starry-platformdiag-waitcaller-20260521.bin
-machine virt -smp 4 -m 4G -accel tcg,thread=single
CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
M6_USE_TMPFS_WORK=0
```

Files:

```text
first attempt:
  showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-directcargo-20260521.log
current rerun:
  showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-directcargo-resume2-20260521.log
panic-context rerun:
  showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-directcargo-resume3-panic-capture-20260521.log
```

Why this route:

- Host QEMU removes Docker daemon overhead from the critical path.
- `tcg,thread=single` is the RISC-V correctness baseline for SMP because MTTCG
  has LR/SC reservation risk.
- `jobs=2` is the next controlled step after subset and scheduler smoke passed.
- Direct rootfs cargo home avoids the tmpfs/CARGO_HOME `chrono` lookup failure
  seen in the previous full attempt.

## Evidence So Far

Short-loop cargo evidence already passed:

```text
===BENCH-CARGO-FOREGROUND jobs=2===
Finished `release` profile [optimized] target(s) in 1m 16s
===BENCH-CARGO t0=0 t1=0 exit=0 jobs=2 sha_jobs=1===
===BENCH-DONE===
```

The full run has reached the real `starry-kernel` lib build and is emitting
heartbeat markers:

```text
banner: arch=riscv64, platform=riscv64-qemu-virt, smp=4
parallelism: mode=multi-vcpu nproc=2 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
[2] cargo build -v --offline -p starry-kernel (lib) --features smp
heartbeat phase=starry-kernel-lib
```

The first direct-cargo attempt progressed through Rust dependencies up to
`alloc/clap_builder`, then the host expect runner hit its old 1800s timeout.
There was no guest panic/trap/FATAL/error at the time of timeout.

The rerun uses an 8-hour expect timeout. It only treats
`===M6-SELFBUILD-PASS===` as final success; `LIB-PASS` is recorded as a stage
marker. On final success, it waits for the shell prompt, runs `sync`, and then
exits QEMU.

The `resume2` run reached `lock_api v0.4.14` in the `starry-kernel-lib` phase
at guest time about 2269s, then emitted `panicked at`. The old expect rule
matched that phrase and immediately quit QEMU, so it truncated the panic body.
That is not enough to attribute the bug to a specific kernel subsystem.

After the forced exit, host fsck repaired many target-directory metadata entries
and a second read-only fsck was clean:

```text
rootfs after forced panic exit: FILE SYSTEM WAS MODIFIED
second e2fsck -fn: clean, 68898/1048576 files, 873924/4194304 blocks
```

The next rerun changes the feedback loop rather than blindly repeating it:
panic/error markers now switch the runner into a short failure-capture window,
wait for the shell prompt, run `sync`, and only then exit QEMU.

Latest `resume3` result on 2026-05-21:

```text
status: failed with captured kernel panic
guest time: about 3228s
latest phase: starry-kernel-lib
latest crates observed: ax-memory-addr, ax-kspin, winnow, clap, serde_core,
  ax-config-gen, ax-config-macros, ax-percpu, ax-percpu-macros
panic:
  panicked at os/arceos/modules/axsync/src/mutex.rs:78:26:
  sleeping or rescheduling is not allowed in atomic context:
  irq_enabled=false, preempt_count=0,
  caller=os/arceos/modules/axsync/src/mutex.rs:78:26
```

Interpretation:

- The previous `resume2` marker was not a random timeout; the rerun crossed it
  and later hit a real OS-level synchronization failure.
- The diagnostic kernel already had RawMutex unlock-before-wake and therefore
  avoided the earlier false self-owner panic. The new panic means a contended
  blocking mutex is being waited on while IRQs are disabled.
- This is not safe to paper over inside `RawMutex`: the fix must either move the
  caller out of atomic context or convert the specific protected data path to a
  non-sleeping lock.
- The next feedback loop is a diagnostic rebuild that reports the outer lock
  caller before the full M6 path is repeated.

Important non-fatal signals:

```text
Unimplemented syscall: riscv_hwprobe
exit robust list failed: AxErrorKind::BadAddress
```

The robust-list warning is being kept as evidence, but it is not yet the first
blocker in this run.

New OS bug candidate extracted from the SMP acceleration path:

```text
area: StarryOS user-space CPU topology
symptom: kernel boots with smp=4, but user-space topology surfaces are incomplete
impact: cargo/nproc and test programs cannot reliably discover or validate all online CPUs
PR candidate: fix(starry): expose SMP CPU topology to user space
test-suite: test-suit/starryos/normal/cpu-topology
local commit: ed6991269 fix(starry): expose SMP CPU topology to user space
local evidence: cargo fmt; git diff --check; host C syntax smoke for the test
push state: blocked by DNS resolution for github.com
```

Pre-run short evidence:

```text
SMP scheduler heartbeat smoke: PASS
M6 subset check: ===M6-SELFBUILD-SUBSET-PASS===
tmpfs cargo-home attempt: failed with missing chrono despite cached crate/index
first direct-cargo attempt: timed out externally after 1800s while still compiling
rootfs fsck after forced kill: repaired target-dir metadata; second fsck clean
second direct-cargo attempt: reached lock_api, panic marker captured but old expect truncated context
panic-capture rerun: reached ax-percpu/ax-percpu-macros, then captured RawMutex wait-in-atomic panic
post-panic fsck: repaired target-dir metadata; second read-only fsck clean
rerun guest df before panic: 16G total, 3.4G used, 13G available
```

The `database or disk is full` line is now known not to mean the rootfs is full.
Cargo prints it while trying to save global-cache last-use data; it has been
non-fatal so far.

## Success Criteria

Strong success:

```text
===M6-SELFBUILD-PASS===
```

Stage success:

```text
===M6-SELFBUILD-KERNEL-LIB-PASS===
```

After a PASS marker:

1. Extract `/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`
   from the rootfs.
2. Save it under `.guest-runs/riscv64-m6/`.
3. Boot-smoke the guest-built kernel with the same rootfs and snapshot mode.

## Failure Handling

If the first failure is a kernel panic/trap or reproducible userland crash:

1. Preserve the first high-signal log lines.
2. Symbolize the PC if there is a kernel address.
3. Build the shortest repro.
4. Patch only the owning OS layer.
5. Add a test-suite case.
6. Prepare a PR body with problem, root cause, fix summary, changed-area
   rationale, tests, and remaining risk.

If the run simply stops producing useful progress for more than 2 hours:

1. Do not just rerun the full build.
2. Add or improve phase/current-crate markers.
3. Replay a smaller cargo target or the latest known phase.
4. Keep the full run as final validation only after the smaller loop explains
   the behavior.

## 2026-05-21 Current Mutex-Owner Diagnostic Run

Current run:

```text
log: showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-mutexowner-resume-20260521.log
kernel: .guest-runs/riscv64-m6-bench/starry-platformdiag-mutexowner-20260521.bin
rootfs: .guest-runs/riscv64-m6-bench/rootfs-bench-run.img
qemu: -smp 4 -m 4G -accel tcg,thread=single
guest cargo: CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
mode: M6_RESUME=1, direct rootfs target/cache, low diagnostic logging
```

Result:

- The run entered `starry-kernel-lib`, kept emitting heartbeat markers, and
  progressed to `lock_api v0.4.14`.
- It failed after about 38 minutes of host time / about 2325 guest seconds with
  a captured kernel panic.
- The rootfs was repaired once after the panic, and the follow-up read-only
  fsck is clean:

```text
e2fsck -fn .guest-runs/riscv64-m6-bench/rootfs-bench-run.img
clean, 69985/1048576 files, 900174/4194304 blocks
```

Captured panic:

```text
panicked at os/StarryOS/kernel/src/mm/access.rs:269:10:
RawMutex would block in atomic context:
waiter=os/StarryOS/kernel/src/mm/access.rs:269:10
owner_task=1066
owner=os/StarryOS/kernel/src/syscall/task/clone.rs:204:55
```

Why this is a shorter feedback loop than the earlier full reruns:

- The previous failure was captured at about 53 minutes but only pointed at
  `axsync::Mutex`.
- This rerun added mutex owner/waiter state and reduced the unknown from
  "some mutex in atomic context" to the exact pair:
  user-memory page-fault handler waiting on the process address-space lock,
  while fork/clone owns that lock.
- That is now an OS-level bug candidate instead of a blind long-run failure.

New PR-quality OS bug extracted during this pass:

```text
branch: fix/starry-usercopy-cold-page
head commit: 179aef0fd fix(starry): prepopulate user strings before read
status: pushed to yks23/tgoskits; draft PR creation blocked by api.github.com
test-suite: /usr/bin/bug-usercopy-cold-page
```

Root cause: normal syscall user-memory access could fault on valid but
untouched anonymous user pages, forcing the fault handler into an IRQ-off path
that may acquire the process address-space mutex. The fix pre-populates user
slices and null-terminated user-string pages in normal syscall context, then
performs no-fault `user_copy` or direct byte reads.

Next controlled rerun:

- Keep the same Linux QEMU container/host QEMU choice, fsck-clean rootfs,
  `-smp 4`, `tcg,thread=single`, `CARGO_BUILD_JOBS=2`,
  `RAYON_NUM_THREADS=2`, and resume mode.
- Replace only the kernel with a build that includes
  `fix/starry-usercopy-cold-page`.
- If the same owner/waiter panic remains, inspect direct user-memory access
  paths that still bypass pre-population; if the run passes this point, the
  next high-signal checkpoint is the first new panic/trap/error or a two-hour
  no-progress stall.
