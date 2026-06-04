# fix: improve StarryOS SMP cargo build progress

## Problem

StarryOS SMP guest builds can make very slow or no visible progress during CPU-heavy user workloads. In the M6 selfbuild path this shows up as long guest cargo phases where helper threads and filesystem/procfs paths must keep making progress while the main rustc/cargo thread is CPU-bound.

## Root Cause

There are several OS-level issues on the SMP path:

- `starry-kernel` did not expose an `smp` feature, so early `cargo build -p starry-kernel --features smp` checks could not directly cover the SMP scheduler/run-queue path.
- Returning from a user interrupt did not ask the task layer to honor a pending preemption request, so a CPU-bound user loop could delay runnable peer work.
- `axsync::RawMutex` handed lock ownership to one waiter during unlock. Under SMP this can interact poorly with wakeup ordering and make diagnosis look like recursive self-locking instead of normal contention.
- procfs paths assumed every `AxTaskRef` was a StarryOS thread. SMP/task-table races can briefly expose non-thread tasks, turning diagnostics paths into panics instead of `ENOENT`-style misses.

## Fix Summary

- Add `smp = ["ax-feat/smp"]` to `starry-kernel`.
- Add `ax_task::resched_if_needed()` and call it when StarryOS returns from a user interrupt.
- Change `axsync::RawMutex::unlock` to release ownership first and wake one waiter to compete for the lock normally; keep a clearer recursive-lock panic message with callsite details.
- Make StarryOS procfs/stat code use `try_as_thread()` and return a normal not-found/no-process error when the task is not a StarryOS thread.
- Add `test-smp-heartbeat`, a StarryOS userland regression case that runs a CPU-bound main thread while a heartbeat pthread must still make progress on `-smp 4`.

## Changed Areas And Why

- `os/StarryOS/kernel/Cargo.toml`: enables direct SMP checking of `starry-kernel`.
- `os/arceos/modules/axtask`: exposes a small scheduler API for honoring pending preemption from kernel return paths.
- `os/StarryOS/kernel/src/task/user.rs`: uses that API at the user interrupt boundary, where it is cheap and semantically tied to rescheduling.
- `os/arceos/modules/axsync/src/mutex.rs`: fixes SMP mutex wakeup behavior and improves failure evidence if recursive locking still happens.
- `os/StarryOS/kernel/src/pseudofs/proc.rs` and `src/task/stat.rs`: makes diagnostic procfs paths robust during concurrent task lifecycle changes.
- `test-suit/starryos/normal/test-smp-heartbeat`: captures the user-visible SMP progress requirement.

## Test Plan

- `cargo fmt --check`
- `git diff --check`
- Docker direct kernel build:

```sh
cargo build -p starryos \
  --target riscv64gc-unknown-none-elf \
  -Z unstable-options \
  --features ax-feat/defplat,ax-feat/smp,qemu \
  --bin starryos --release
```

Result: PASS in 2m27s inside `auto-os/starry:latest`.

- Manual QEMU smoke with the built RISC-V SMP kernel:

```text
smp = 4
online cpus: 4
heartbeat during busy loop: 8
TEST PASSED
===SMP-HEARTBEAT-RC:0===
```

## Remaining Risk

The manual smoke used an injected rootfs copy because the local Mac host lacks the RISC-V musl toolchain needed by the full StarryOS test runner. After pushing the branch, GitHub Actions should run the normal test-suite path before the PR is marked ready.
