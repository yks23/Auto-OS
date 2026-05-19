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

## OS Work Needed For Real Speed

These are the OS-level improvements that can plausibly turn SMP correctness
into acceleration:

1. Scheduler fairness under CPU-bound user code.
   - Current fix: reschedule on user interrupt return.
   - Next proof: heartbeat/cargo progress under `jobs=2` and `jobs=4`.

2. Mutex and futex wakeup behavior.
   - Current fix candidate: RawMutex releases ownership before waking a waiter.
   - Next proof: multi-thread lock/futex stress plus cargo workload.

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

5. Same benchmark with `M6_TCG_THREAD=multi` for speed signal.
6. `demo-m6-selfbuild.sh --subset` with `SMP=4`, `jobs=2`.
7. Full M6 only after the short lanes explain what changed.

## Claim Discipline

- If only `thread=single` passes: claim SMP correctness progress, not speedup.
- If `thread=multi` is faster but `thread=single` has not passed the matching
  workload: claim speed signal only.
- If both pass and the workload is StarryOS/cargo, claim guest parallel build
  progress.
- If real hardware/KVM also passes, then claim true multi-core acceleration.
