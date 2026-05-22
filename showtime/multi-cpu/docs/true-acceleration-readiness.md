# True Acceleration Readiness

## Current State

We now have the first useful SMP readiness signal:

- StarryOS SMP kernel can be built on the current `dev` baseline.
- A 4-HART RISC-V StarryOS boot reaches userland.
- A CPU-bound user thread no longer fully starves a heartbeat pthread in the
  short smoke:

```text
smp = 4
online cpus: 4
heartbeat during busy loop: 8
TEST PASSED
===SMP-HEARTBEAT-RC:0===
```

This proves scheduler responsiveness at a small scale. It is not yet a proof
that full M6 selfbuild is faster.

Latest 2026-05-21 kernel evidence:

```text
8-HART boot: PASS at -smp 8 -m 4G -accel tcg,thread=single
StarryOS banner: smp = 8
smoke marker: TEST PASSED / ===MTTCG-BENCH-DONE===
```

This proves the kernel can bring up 8 HARTs and run userland at 4G. It is not
a full M6 result.

The first 8-HART memory blocker is allocator metadata capacity, not CPU
bring-up:

```text
-smp 8, 6G: bitmap capacity exceeded
need 1572864 pages, CAP is 1048576 pages
-smp 8, 4G: boots to userland and smoke passes
```

So the current workaround is `-m 4G`; the real OS fix is to make the bitmap
allocator capacity match the platform memory layout or allocate metadata
dynamically.

The futex wait path also exposed a PR-sized kernel bug. `FUTEX_WAIT` must
recheck the user word while serializing against wakeup, but the old recheck used
normal `vm_read()` while the wait queue held a no-IRQ spinlock. That can call
`prepare_user_memory` and take the address-space mutex in atomic context. The
narrow fix is:

- first read: normal `uaddr.vm_read()` before the wait-queue lock;
- locked recheck: `vm_read_u32_noprepare(uaddr)`, which only validates the
  range and copies the already-present 32-bit word without page preparation;
- regression: a pthread `FUTEX_WAIT|PRIVATE` waiter that is woken by
  `FUTEX_WAKE|PRIVATE` must return 0 without an atomic usercopy warning.

Raw CPU MTTCG speed signal is now measured with a syscall-only benchmark:

```text
workload: /usr/bin/smp-raw-bench, 400000000 total loop iterations
single TCG 4/8 workers: 897394 us / 1010162 us
multi  TCG 4/8 workers: 325329 us / 318373 us
speedup: 2.76x / 3.17x
```

This is a real parallel-execution signal. It is still only a speed signal:
RISC-V MTTCG is not the correctness baseline for futex-heavy Rust/Cargo work.

The full-M6 result is still open, but it has split into two clearer lanes:

```text
SMP=8, TCG=multi, CARGO_BUILD_JOBS=4, RAYON_NUM_THREADS=4, -m 4G
tmpfs target: early build-script Exec format error
ext4 target: passed the tmpfs early failure point and continues in starry-kernel-lib
guest topology note: kernel banner is smp = 8, but nproc still reports 2
```

The tmpfs lane now points at a focused filesystem/exec regression: cargo writes
a temporary executable, renames it, then immediately execs the final path. Tmpfs
stores ordinary file bytes in page cache tied to file location/user data, so a
rename can expose valid metadata with missing or wrong cached bytes. The ext4
lane is therefore the main long cargo validation route, while tmpfs should be
reduced with a short rename-readback-exec test. There is still no
`===M6-SELFBUILD-PASS===` marker on the multi-core lane.

## What "Real Acceleration" Means

The final claim must compare wall-clock time under controlled conditions:

| lane | purpose | correctness value | speed value |
| --- | --- | --- | --- |
| `SMP=1, TCG=single, jobs=1` | stable baseline | high | baseline |
| `SMP=4, TCG=single, jobs=2/4` | StarryOS SMP correctness under cargo pressure | high | low, because host TCG is serialized |
| `SMP=4, TCG=multi, jobs=2/4` | host-side parallel execution signal | low by itself on RISC-V TCG | high if it survives |
| real hardware or KVM-capable same-arch VM | final performance evidence | high | high |

For RISC-V QEMU TCG, `thread=multi` cannot be the only correctness proof
because LR/SC reservation modeling is risky under MTTCG. The clean story is:

1. prove StarryOS SMP correctness with `thread=single`;
2. measure speed signal with `thread=multi`;
3. confirm with real hardware/KVM when available.

## Prepared Short Loops

### Feedback discipline

- A confirmed OS bug must become a PR candidate: root cause, minimal kernel or
  syscall/filesystem fix, focused test-suite case, and validation notes.
- If a feedback path is longer than two hours, stop using it as the primary
  diagnostic and shorten the loop first.
- If there is no concrete bug, add high-signal logs before rerunning:
  phase, heartbeat, current crate/process, panic/trap PC, guest exit status,
  and PASS/FAIL markers.

### 1. Kernel-only compile gate

Use this before any long guest run:

```sh
docker run --rm \
  -v "$(pwd)/tgoskits":/work -w /work \
  -v "$HOME/.cargo/registry":/usr/local/cargo/registry \
  -v "$HOME/.cargo/git":/usr/local/cargo/git \
  -e RUSTUP_TOOLCHAIN=nightly-2026-04-01-x86_64-unknown-linux-gnu \
  -e CARGO_NET_OFFLINE=true \
  -e AX_ARCH=riscv64 \
  -e AX_TARGET=riscv64gc-unknown-none-elf \
  -e AX_LOG=warn \
  -e AX_PLATFORM=riscv64-qemu-virt \
  -e SMP=4 \
  auto-os/starry:latest \
  bash -lc 'cargo build -p starryos --target riscv64gc-unknown-none-elf --features ax-feat/defplat,ax-feat/smp,qemu --bin starryos --release'
```

This catches Rust/kernel integration failures in minutes, not hours.

### 2. SMP heartbeat smoke

Use the `test-smp-heartbeat` test-suite case or the equivalent manual QEMU
smoke to check:

- kernel boots with `smp = 4`;
- userland sees `online cpus: 4`;
- a heartbeat pthread runs while another user thread is CPU-bound.

### 3. Benchmark harness

`scripts/bench-m6-guest-smp.sh` now supports:

```sh
M6_TCG_THREAD=single bash scripts/bench-m6-guest-smp.sh
M6_TCG_THREAD=multi  bash scripts/bench-m6-guest-smp.sh
```

The default remains `single`. Use `multi` only for speed-signal runs, and keep
its output separate from correctness evidence.

### 4. Raw CPU MTTCG benchmark

Use the raw syscall CPU benchmark before returning to cargo-sized speed claims:

```text
showtime/multi-cpu/benchmarks/raw-cpu-mttcg-20260521.md
showtime/multi-cpu/logs/speed-rawcpu-single-smp4-i400m-seq-20260521.log
showtime/multi-cpu/logs/speed-rawcpu-multi-smp4-i400m-seq2-20260521.log
```

It validates `clone + wait4 + exit` under CPU load in seconds and gives stable
speed numbers without Cargo, dynamic linking, or filesystem pressure.

### 5. 8-HART boot and memory cap

Keep the 8-HART smoke short:

```text
-smp 8 -m 4G -accel tcg,thread=single: boot/userland smoke
-smp 8 -m 6G: allocator capacity regression, expected to fail until fixed
```

Do not spend a full selfbuild run on the 6G case until the allocator metadata
capacity has a direct kernel fix.

## OS Work Needed For Real Speed

These are the OS-level improvements that can plausibly turn SMP correctness
into acceleration:

1. Scheduler fairness under CPU-bound user code.
   - Current fix: reschedule on user interrupt return.
   - Next proof: heartbeat/cargo progress under `jobs=2` and `jobs=4`.

2. Mutex and futex wakeup behavior.
   - Current fix candidate: futex wait recheck uses a no-prepare user read
     while the wait queue is locked, after the sleepable first read already
     validated the futex word.
   - Next proof: `bug-futex-wait-wake` under QEMU, then re-run the 8-HART cargo
     smoke far enough to prove the atomic-context futex warning is gone.

3. User-task migration safety.
   - Current policy: keep user tasks conservative while kernel tasks may use
     load-based placement.
   - Next proof: syscall-after-wakeup regression and procfs task walks while
     kernel tasks are active.

4. Filesystem and page-cache scalability.
   - Full cargo builds stress ext4, tmpfs, metadata locks, mmap, and sync paths.
   - Next proof: isolate tar/readback and cargo target-dir write pressure into
     small filesystem regressions.

5. Progress visibility.
   - Keep low log volume by default, but preserve heartbeat and phase markers.
   - A silent run is not enough evidence; every long run needs progress CSV and
     high-signal markers.

6. User-space CPU topology.
   - Current PR candidate: expose runtime `ax_hal::cpu_num()` through sysconf,
     procfs, sysfs, and affinity/status reporting.
   - Why it matters: build tools and validation scripts need to see the same
     CPU count that the kernel booted, otherwise a 4-HART kernel can silently
     run only a 2-way cargo workload or fail topology checks.

7. Allocator capacity for larger SMP guests.
   - Current evidence: 8-HART 6G boot panics because the bitmap allocator CAP is
     4G worth of pages.
   - Next proof: direct boot regression for `-smp 8 -m 6G` after allocator
     metadata is made dynamic or sized from platform memory.

8. Tmpfs rename/readback/exec consistency.
   - Current evidence: the tmpfs target lane produced a build-script
     `Exec format error`, while the ext4 target lane passed the same early
     point.
   - Next proof: a short regression that writes an ELF to tmpfs, renames it,
     checks the final ELF magic, then `fork` + `execve`s the renamed path.

## Next Run Order

Do not jump straight to an 8-hour full run unless these pass:

1. `cargo fmt --check`, `git diff --check`.
2. Docker kernel-only SMP build.
3. SMP heartbeat smoke.
4. `bench-m6-guest-smp.sh` with `M6_TCG_THREAD=single`, short SHA-only mode:

```sh
M6_BENCH_SKIP_CARGO=1 \
M6_BENCH_SHA256_TOTAL_MB=64 \
M6_BENCH_SHA_JOBS="1 4" \
M6_TCG_THREAD=single \
bash scripts/bench-m6-guest-smp.sh
```

5. Raw CPU MTTCG benchmark as the cheap speed signal; record both logs and
   exact worker timings.
6. `-smp 8 -m 4G` boot smoke. Keep `-m 6G` as the allocator regression until
   the bitmap capacity issue is fixed.
7. Futex wait/wake regression with the no-prepare locked recheck.
8. Keep the current ext4 full-M6 lane running as the long cargo validation
   route.
9. Reduce the tmpfs build-script `Exec format error` with a short
   rename-readback-exec regression instead of using full M6 as its diagnostic.
10. Full M6 PASS is claimed only after a marker is printed and the guest-built
    kernel is extracted and boot-smoked.

## Claim Discipline

- If only `thread=single` passes: claim SMP correctness progress, not speedup.
- If `thread=multi` is faster but `thread=single` has not passed the matching
  workload: claim speed signal only.
- If both pass and the workload is StarryOS/cargo, claim guest parallel build
  progress.
- If real hardware/KVM also passes, then claim true multi-core acceleration.
