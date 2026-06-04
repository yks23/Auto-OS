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
   - `过程记录/早期记录/multi-cpu/docs/os-kernel-smp-issues.md`
   - 重点只记录 OS 层问题：用户态 timer 抢占、用户任务迁移亲和性、run queue load 和诊断 callsite。

## 当前实验改动

| area | file | change | status |
| --- | --- | --- | --- |
| futex | `os/StarryOS/kernel/src/syscall/sync/futex.rs` | 支持 `FUTEX_PRIVATE_FLAG` | 实验中 |
| mutex | `os/arceos/modules/axsync/src/mutex.rs` | unlock 先释放 owner/state，再 wake waiter | 实验中 |
| usercopy/mm | `os/StarryOS/kernel/src/mm/access.rs` | 非 StarryOS thread context 的 usercopy 返回 access error；page fault 路径避免重入持有中的 address-space lock | 实验中 |
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

## 2026-05-22 SMP8 jobs=4 pass2 bug narrowing

Command shape:

```text
M6_KERNEL=.guest-runs/riscv64-m6/starry-smp8-rawmutex-nosend-zerolen-20260522.bin
M6_ROOTFS=.guest-runs/rootfs-selfbuild-full-smp8-ext4-j4-robust-repro-20260522.img
M6_TCG_THREAD=single
```

Purpose:

- Keep correctness mode at QEMU `tcg,thread=single`.
- Reproduce the previous `jobs=4` pass2 failure from a snapshot rootfs, without
  rerunning all M6 preparation steps.
- Turn late guest cargo failures into concrete kernel fixes with shorter
  validation windows.

Kernel findings:

- First failure: `access_user_memory called outside of thread context`.
  Current fix: guard `VmIo::read/write` before entering `access_user_memory` and
  return `VmError::AccessDenied` instead of panicking.
- Second failure: `Thread(89) tried to acquire mutex it already owns` at the
  StarryOS address-space lock site. Current fix: `RawMutex::unlock()` releases
  `owner_id` before waking one waiter, so ownership is only published after the
  woken task wins the normal CAS path.
- Third failure: at 846s, `idle` tried to release a mutex owned by another
  task after a zero-length non-thread usercopy warning. Current fix:
  zero-length usercopy returns success before context checks, and `RawMutex`
  uses `GuardNoSend` because ownership is tracked by task id.

Validation so far:

```text
cargo fmt --check --manifest-path os/StarryOS/starryos/Cargo.toml
MAX_CPU_NUM=8 bash scripts/build.sh ARCH=riscv64
short snapshot: crossed old 72s/149s/223s failure windows and reached syn v1.0.109
long snapshot: reached 1265s host timeout and clap_builder v4.6.0, with no panic/trap/FATAL/error
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/m6-smp8-robust-repro-tcgsingle-j4-pass2-fullpanic-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-usercopyfix-repro-tcgsingle-j4-pass2-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-rawmutex-release-wakeup-repro-tcgsingle-j4-pass2-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-rawmutex-release-wakeup-long-tcgsingle-j4-pass2-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-rawmutex-nosend-zerolen-tcgsingle-j4-pass2-20260522.log
```

PR candidate:

- Title shape: `fix(sync): release mutex before waking SMP waiter`
- Test-suit case: `test-suit/starryos/normal/qemu-smp4/test-rawmutex-handoff`
- Focused test status: the C case builds and passes as a host sanity check.
  The StarryOS `cargo xtask starry test qemu --arch riscv64 -g normal -c
  test-rawmutex-handoff` path now reaches the test runner, but this macOS host
  lacks `qemu-riscv64`/`qemu-riscv64-static` for the runner's user-mode
  precheck. Do not keep rerunning the full test locally; use CI/Linux or a
  Docker image with qemu-user for the final PR check.

## 2026-05-20 dev baseline short SMP guest benchmark

Command shape:

```text
M6_QEMU_SMP=4 M6_TCG_THREAD=single M6_BENCH_SKIP_CARGO=1
M6_BENCH_SHA256_TOTAL_MB=32 M6_BENCH_SHA_JOBS=1/2/4
M6_BENCH_KERNEL_ELF=/private/tmp/tgoskits-dev-local/target/riscv64gc-unknown-none-elf/release/starryos
```

Purpose:

- Continue on the current TGOSKit `origin/dev` baseline, not the older
  migration branch.
- Use a seconds-level loop before trying another full guest cargo build.
- Keep QEMU correctness mode at `-accel tcg,thread=single`.

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-sha1-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-sha2-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-sha4-20260520.log
```

Result:

```text
sha_jobs=1: PASS, host wall 4s, BENCH-DONE
sha_jobs=2: FAIL, host wall 6s, Segmentation fault, BENCH-SHA-FAIL
sha_jobs=4: FAIL, host wall 8s, Segmentation fault, BENCH-SHA-FAIL
```

Follow-up isolation:

```text
workload=dd, sha_jobs=1: PASS, host wall 4s
workload=dd, sha_jobs=2: FAIL, host wall 4s, Segmentation fault
```

Additional evidence:

```text
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-dd1-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-dd2-20260520.log
```

Interpretation:

- The latest blocker is no longer a multi-hour mystery: two concurrent
  `dd | sha256sum` pipelines inside an SMP StarryOS guest can reproduce the
  failure in seconds.
- Forcing pure `dd of=/dev/null` still reproduces the failure at two workers,
  so this is not specific to `sha256sum` or pipe hashing.
- QEMU exits normally, so the first visible failure layer is guest userland;
  because the failure only appears with parallel guest processes, the next OS
  work is to reduce it to scheduler/mm/futex/pipe/process regression tests.
- The benchmark harness now treats guest segfaults and missing `BENCH-DONE` as
  failures instead of silently reporting a successful run.

## 2026-05-20 direct I/O fix and shell wait isolation

Short-loop change:

- Fixed direct VFS I/O so non-cacheable device reads/writes continue across the
  internal 2048-byte transfer buffer while the device keeps making full-chunk
  progress.
- Added a StarryOS test-suite case for `/dev/zero` full read and `/dev/null`
  full write semantics.

Validation:

```text
Docker target build: cargo build -p starryos --target riscv64gc-unknown-none-elf --features ax-feat/defplat,ax-feat/smp,qemu --release
Result: PASS, release build finished in 47.80s on the fixed direct-I/O kernel

QEMU: SMP=4, TCG=single, 128M matched to the temporary axconfig
test-dev-zero-full-transfer: PASS
dd direct background case: PASS, statuses 0 0
dd function/subshell background case: FAIL, wait status 124 despite inner ddrc=0
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/devzero-full-transfer-fixed-20260520.log
过程记录/早期记录/multi-cpu/logs/shellcase-direct-dd-bg-20260520.log
过程记录/早期记录/multi-cpu/logs/shellcase-function-dd-bg-20260520.log
过程记录/早期记录/multi-cpu/logs/shellcase-function-inner-ddrc-20260520.log
过程记录/早期记录/multi-cpu/logs/shellcase-function-inner-info-20260520.log
```

Interpretation:

- The earlier `dd` failure had two layers. The `/dev/zero`/`/dev/null` short
  transfer layer is fixed and reproducible as a small filesystem/device
  regression.
- The remaining multi-process blocker is narrower: Bash background subshells
  can report wait status 124 even when their inner `dd` exits 0 and the kernel
  info log records the subshell task exiting with code 0.
- Therefore the next OS fix should target process wait/exit status semantics
  for nested background subshells, not device I/O.

## 2026-05-20 waitpid double-check and fork+exec follow-up

Short-loop change:

- Added a second child-status check after `child_exit_event.register(cx.waker())`
  in `sys_waitpid`.
- Purpose: close the classic check/register lost-wakeup window where a child can
  exit after the parent observes no zombie child but before the parent registers
  its waker.

Validation:

```text
pure fork/_exit wait regression: PASS
fork+exec /bin/true wait regression: FAIL after round 128
Bash function + /bin/true background wait: FAIL, statuses 124/139
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/waitpid-child-exit-wakeup-fixed-20260520.log
过程记录/早期记录/multi-cpu/logs/waitpid-child-exit-wakeup-exec-waitfix-20260520.log
过程记录/早期记录/multi-cpu/logs/shellcase-function-true-waitfix-20260520.log
```

Interpretation:

- The double-check is a real fix for one lost-wakeup shape, but it is not the
  full SMP process/exec fix.
- The fork+exec regression now exposes the next kernel-level blocker:
  `axtask::WaitQueue::wait_until` panics with `irq_enabled=false,
  preempt_count=0` while running an SMP guest.
- The next shortest loop should keep the fork+exec C testcase and add
  caller/state diagnostics around the task join/wait path, instead of returning
  to a full M6 cargo build.

## 2026-05-20 synthetic cargo feedback split

Short-loop improvements:

- `scripts/bench-m6-guest-smp.sh` now has a fully self-contained synthetic
  cargo workspace mode. This avoids false late failures from incomplete
  offline crates.io cache while still exercising guest Cargo, rustc, fork/exec,
  threads, filesystem writes, and wait paths.
- The guest C compiler wrapper now uses the Alpine/musl toolchain under
  `/opt/alpine-rust/usr/bin` instead of falling back to Debian
  `riscv64-linux-gnu` or missing `clang`.
- Cargo now emits `===BENCH-CARGO-HEARTBEAT===` markers and tails the cargo
  log every 30 seconds, so a silent serial log is no longer mistaken for a
  hang.
- `M6_BENCH_CARGO_JOBS` separates cargo parallelism from the preceding
  `sha_jobs`/dd workload. This makes the test a proper control-variable loop.

Validation:

```text
SMP=4, TCG=single, workload=dd, synthetic native cargo, crates=8
sha_jobs=1, cargo_jobs=1: PASS, host wall 166s, cargo finished in 2m16s
sha_jobs=1, cargo_jobs=2: FAIL, host wall 47s, kernel Supervisor Page Fault
sha_jobs=2, cargo_jobs=2: FAIL, host wall 45s, BENCH-CARGO-FAIL rc=139
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j1-pass-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j2-fail-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-fail-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-summary-fail-20260520.txt
```

## 2026-05-21 platformdiag M6 run

Long-run rule in effect:

- A confirmed OS bug becomes a PR candidate: root cause, minimal OS patch,
  focused test-suite case, and validation notes.
- If the feedback loop exceeds 2 hours without a useful signal, shorten the
  loop before rerunning the same path.
- If no concrete bug is visible, add high-signal logs instead of guessing.

Short-loop evidence before the full run:

```text
SMP scheduler smoke: PASS
M6 subset / metadata offline check: ===M6-SELFBUILD-SUBSET-PASS===
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/smp4-scheduler-heartbeat-smoke-20260521.typescript
过程记录/早期记录/multi-cpu/logs/m6-smp4-subset-platformdiag-20260521.typescript
```

The first full `jobs=2` attempt with tmpfs workdir failed early:

```text
error: no matching package named `chrono` found
location searched: crates.io index
required by package `ax-arm-pl031`
```

That rootfs contains the `chrono-0.4.44.crate` and sparse index entry, so this
is currently treated as a guest tmpfs/CARGO_HOME path issue rather than a
missing dependency. The run was switched back to the direct rootfs cargo home
to keep the correctness lane moving.

Current full run result:

```text
kernel: .guest-runs/riscv64-m6-bench/starry-platformdiag-mutexowner-20260521.bin
QEMU: -machine virt -smp 4 -m 4G -accel tcg,thread=single
CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
M6_USE_TMPFS_WORK=0
log: 过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-mutexowner-resume-20260521.log
```

Observed result:

```text
banner: arch=riscv64, platform=riscv64-qemu-virt, smp=4
guest parallelism line: mode=multi-vcpu nproc=2 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
phase: starry-kernel-lib
progress: reached lock_api v0.4.14
fatal signal: captured kernel panic
host elapsed: about 38 minutes
guest elapsed: about 2325 seconds
```

Notes:

- The kernel sees 4 harts, but the guest `nproc` currently reports 2, so the
  active cargo lane is a controlled 2-way parallel build.
- `exit robust list failed: AxErrorKind::BadAddress` appears during some rustc
  exits. It is a useful warning and PR evidence only if the current branch does
  not already include the robust-list cleanup fix; so far it has not stopped
  the run.
- The mutex-owner diagnostic kernel turned the generic RawMutex panic into an
  exact owner/waiter pair:

```text
waiter=os/StarryOS/kernel/src/mm/access.rs:269:10
owner=os/StarryOS/kernel/src/syscall/task/clone.rs:204:55
```

- This points to user-memory page-fault handling trying to take the process
  address-space lock while fork/clone owns it. Because the page-fault path runs
  with IRQs disabled, normal syscall user-memory access should pre-populate
  user pages instead of relying on trap-time population.
- A separate `riscv_hwprobe` compatibility branch has been prepared in
  `/private/tmp/tgoskits-riscv-hwprobe` on top of `origin/dev`. It implements a
  conservative RISC-V hwprobe path and adds a RISC-V test-suit case. It is not
  being claimed as the M6 correctness fix; it reduces ABI/log noise from Rust
  feature detection.

Outcome of the first direct-cargo run:

```text
host result: expect timeout after 1800s
last useful phase: starry-kernel-lib, compiling alloc/clap_builder
PASS marker: none
panic/trap/fatal: none
```

Important correction:

- This was not an OS panic. The guest was still emitting heartbeat markers and
  compiling crates when the outer expect runner killed QEMU.
- The outer runner is now changed to 28800s and waits for the final
  `===M6-SELFBUILD-PASS===` marker. `LIB-PASS` is treated only as a stage
  marker.
- On final PASS, the runner waits for the shell prompt, runs `sync`, and only
  then exits QEMU.

Rootfs state after the forced kill:

```text
e2fsck repaired many target-dir deleted/unused inode, refcount, and bitmap issues
second e2fsck: clean
debugfs stats: 68485/1048576 files, 867696/4194304 blocks
guest df before rerun: 16G size, 3.4G used, 13G available
```

Interpretation:

- The `database or disk is full` warning is not caused by the rootfs being full.
  It is Cargo failing to save global-cache last-use data and is currently
  non-fatal.
- The heavy fsck repair cannot yet be claimed as an OS filesystem bug because
  it followed a forced QEMU exit. It should become a filesystem PR only if the
  same corruption appears after a graceful guest `sync`/shutdown or in a small
  reproducer.

Second direct-cargo run:

```text
log: 过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-directcargo-resume2-20260521.log
runner timeout: 28800s
initial guest df: 16G total, 13G available
target after fsck: 28K, so this is effectively a clean target rebuild
status: running
```

PR candidate status:

```text
branch: fix/riscv-hwprobe-compat
scope: syscall ABI compatibility / log-noise reduction
local checks: cargo fmt --check PASS, git diff --check PASS
C syntax smoke: PASS with macOS deprecation warning disabled for syscall()
blocked check: cargo check reaches lwext4_rust, then host lacks executable riscv64-linux-musl toolchain
blocked Docker check: Docker Desktop API returns 500
```

Interpretation:

- The corrected control loop now shows cargo `-j2` itself can trigger an SMP
  kernel fault even when the preceding workload is single-worker dd.
- The failure appears after cargo starts compiling two independent synthetic
  leaf crates. The trap maps to `starry_kernel::syscall::io_mpx::poll::do_poll`
  while updating `pollfd.revents`; the faulting write target is a low user
  address (`fault_vaddr=0x40f0b96`) reached from supervisor mode.
- The earlier two-worker background dd failure remains useful evidence, but it
  is no longer the only trigger. The next OS focus is the `ppoll`/pipe/waker
  path used by rustc/cargo's parallel jobserver and child-process monitoring.
- Under QEMU `tcg,thread=single`, host-wall cargo speedup is not expected even
  with multiple guest vCPUs. This mode is still the correctness baseline.
  True speed signal must use MTTCG or real hardware/KVM and must be labeled
  separately because RISC-V MTTCG has known LR/SC correctness risk.

## 2026-05-20 ppoll user-buffer fix validates cargo -j2

Root cause isolated:

- The failing `cargo -j2` path enters `ppoll` while cargo/rustc monitor child
  processes and jobserver pipes.
- The dev baseline `sys_ppoll` path kept mutable references into the user
  `pollfd` array while `block_on(poll_io(...))` could sleep and later resume.
  On resume, the kernel wrote `revents` through that user address from
  supervisor mode and hit:

```text
Unhandled Supervisor Page Fault @ 0xffffffc08033a122
fault_vaddr=VA:0x40f0b96 (WRITE)
symbol: starry_kernel::syscall::io_mpx::poll::do_poll::{closure...}
```

Fix in `/private/tmp/tgoskits-dev-local`:

- Read the `pollfd` array into a kernel-owned `Vec<pollfd>` before polling.
- During `poll_io`, update only the kernel copy and preserve indices.
- After `do_poll` returns, write only `revents` back to the original user
  buffer with `vm_write_slice`.
- Added test-suite case:
  `test-suit/starryos/normal/test-ppoll-user-buffer`.

Validation:

```text
dev-local SMP4 kernel build: PASS
SMP=4, TCG=single, synthetic native cargo, sha_jobs=1, cargo_jobs=2 foreground: PASS
host_qemu_wall_seconds=195
===BENCH-CARGO t0=0 t1=0 exit=0 jobs=2 sha_jobs=1===
===BENCH-DONE===
```

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-fail-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-pass-20260520.log
过程记录/早期记录/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-summary-pass-20260520.txt
```

Remaining issue:

- The background-heartbeat harness also completed cargo, but did not print
  `BENCH-DONE` after `wait "$cargo_pid"`. Foreground cargo proves the compile
  itself works; the background variant is now a separate wait/exit-status
  cleanup issue.

## 2026-05-21 host QEMU SMP4 jobs=2 full self-build attempt

Command shape:

```text
host qemu-system-riscv64
-machine virt -smp 4 -m 4G -accel tcg,thread=single
CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2 M6_RESUME=1
```

Purpose:

- Move the long correctness run out of the Docker daemon path after Docker
  became an avoidable feedback bottleneck.
- Keep the RISC-V correctness baseline at `tcg,thread=single`.
- Reuse the rootfs/checkpoint state while changing only the kernel and guest
  build configuration.
- Exercise real guest Cargo/rustc parallelism, not only a synthetic workload.

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/hostqemu-smp4-threadsingle-m4g-cargo-rerun-20260521.serial.log
过程记录/早期记录/multi-cpu/logs/hostqemu-m6-full-j2-smp4-20260521.serial.log
过程记录/早期记录/multi-cpu/logs/run-tests-full-j2-20260521.sh
```

Fast evidence before the full run:

```text
===BENCH-CARGO-FOREGROUND jobs=2===
Finished `release` profile [optimized] target(s) in 1m 16s
===BENCH-CARGO t0=0 t1=0 exit=0 jobs=2 sha_jobs=1===
===BENCH-DONE===
```

Live full-run status:

- The run has entered StarryOS guest userland and started the real
  `starry-kernel` lib build.
- Guest parallelism is explicit:

```text
parallelism: CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2
[2] cargo build -v --offline -p starry-kernel (lib) --features smp
```

- The serial log is emitting 30-second `heartbeat phase=starry-kernel-lib`
  markers, so current silence between crate lines is observable work, not a
  blind wait.
- Recent crates include `core`, `proc-macro2`, `quote`, `syn v2.0.117`,
  `strum_macros`, `ax-errno`, `ax-crate-interface`, and `syn v1.0.109`.
- At the time of this note there is no full PASS marker yet, and no captured
  `panic`, `trap`, `Segmentation`, or Rust `error: could not compile`.

Result rule:

- If it prints `===M6-SELFBUILD-PASS===` or
  `===M6-SELFBUILD-KERNEL-LIB-PASS===`, extract the guest-built
  `/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos` and boot
  smoke it as a separate proof.
- If it fails with a kernel panic/trap or a reproducible userland crash, reduce
  that to an OS-level bug and prepare a TGOSKit PR with a test-suite case.
- If it runs longer than two hours without a new phase or useful progress
  signal, shorten the loop before rerunning: add better markers, reduce the
  build target, or replay the failing phase with a smaller guest workload.

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
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-subset-v20-user-timer-yield.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-subset-v20-user-timer-yield.progress.csv
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
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v21-user-timer-yield-early.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v21-user-timer-yield-early.progress.csv
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
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v22-kernel-smp-feature.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-full-v22-kernel-smp-feature.progress.csv
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
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v26-resched-if-needed.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v27-mutex-caller.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-threadsingle-j2-clean-upstream-v28-mutex-unlock-competitive.log
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
- The guest serial log then stopped growing after the heartbeat at
  `2026-05-19T10:12:57Z`; the progress monitor still reported the same
  `log_bytes=500192` and `log_lines=3041` up to elapsed `15390s`.
- The container exited at about `2026-05-19T12:17Z` after the stall detector
  boundary. The captured guest serial log contains no `===M6-SELFBUILD-PASS===`
  marker, no kernel panic/trap, and no Rust compile error.
- Final v28 result: **no PASS, no visible crash, serial-log stall during a
  long `futures-util`/`starry-kernel-lib` rustc phase**.

Interpretation:

- The `RawMutex` unlock-before-wake experiment is still meaningful because it
  passed the earlier self-owner panic point.
- The next smaller OS regression should focus on guest progress under
  `SMP=4 + jobs=2`: timer/preemption responsiveness while long CPU-bound
  rustc processes run, plus blocking mutex wakeup and address-space/page-fault
  locking under parallel user tasks.

## 当前产物位置

尚未复制到 showtime artifact 目录。实验产物仍在：

- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.bin`
- `/private/tmp/tgoskits-futex-private/os/StarryOS/starryos/starryos_riscv64-qemu-virt-smp4-fixed.elf`

## 还没有完成

- 多轮 benchmark。
- M6 级别 guest cargo build 的稳定加速验证；当前 `SMP=4 + thread=single + jobs=2`
  已经越过 v27 的 `quote` mutex panic，并推进到 `futures-util` 一带，但 v28
  最终因为串口日志长时间不增长而退出，没有 full PASS。
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
过程记录/早期记录/multi-cpu/logs/m6-smp4-mttcg-j4.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-mttcg-j4.done
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

## 2026-05-21 M6 SMP4 J2 Mutex-Owner Diagnostic

Result:

```text
过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-mutexowner-resume-20260521.log
```

Environment:

```text
QEMU: -smp 4 -m 4G -accel tcg,thread=single
kernel: .guest-runs/riscv64-m6-bench/starry-platformdiag-mutexowner-20260521.bin
rootfs: .guest-runs/riscv64-m6-bench/rootfs-bench-run.img
CARGO_BUILD_JOBS=2
RAYON_NUM_THREADS=2
M6_RESUME=1
```

Interpretation:

- This is a correctness-baseline SMP run, not an MTTCG speed proof.
- The run entered `starry-kernel-lib`, continued to produce heartbeat and
  syscall activity, and reached `lock_api v0.4.14`.
- It then emitted a captured `RawMutex would block in atomic context` panic.
- The diagnostic payload identified the exact contention:

```text
waiter=os/StarryOS/kernel/src/mm/access.rs:269:10
owner=os/StarryOS/kernel/src/syscall/task/clone.rs:204:55
```

- This means a user-memory page fault tried to take the process address-space
  lock while fork/clone owned it. Since the fault path is IRQ-off, normal
  syscall user-memory paths should pre-populate pages before touching them.
- Post-panic `e2fsck -fn` is clean after one repair pass:
  `69985/1048576 files, 900174/4194304 blocks`.

PR work extracted from this loop:

- `fix/starry-usercopy-cold-page @ 179aef0fd` has been pushed to
  `yks23/tgoskits`.
- The branch now covers cold output slices and cold null-terminated user
  strings, with `/usr/bin/bug-usercopy-cold-page` in the RISC-V bugfix group.
- The draft PR could not be created because local `gh` cannot access GitHub API
  through the current keyring/network path.
- Local evidence and PR body are tracked in
  `success-pr/pr-usercopy-cold-page-draft.md`.

## 2026-05-21 User-Copy PR Kernel Reruns

Short-loop change:

- Rebuilt a diagnostic kernel with the `fix/starry-usercopy-cold-page` shape:
  pre-populate user slices/strings before no-fault access, avoid holding
  `IrqSave` across that pre-populate, and skip re-locking the current task's
  own address-space mutex.
- Kept control variables fixed: same SMP4 QEMU correctness mode, same rootfs
  clone, same `CARGO_BUILD_JOBS=2` / `RAYON_NUM_THREADS=2`, same direct rootfs
  cargo home.

Evidence files:

```text
过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-usercopy-resume2-20260521.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-usercopy-noirq-resume-20260521.log
过程记录/早期记录/multi-cpu/logs/m6-smp4-j2-platformdiag-usercopy-ownerguard-resume-20260521.log
```

Results:

```text
resume2: failed in about 6.7s; experimental tree still held IrqSave in VmIo::new
noirq: failed in about 9s; same-task aspace lock re-entry during M6_RESUME scan
ownerguard: reached real cargo; compiled compiler_builtins/core/proc-macro2;
  failed around guest time 72s with owner=syscall/mm/mmap.rs:276:56
```

Interpretation:

- The old `clone.rs` owner blocker was reduced to a PR branch with a focused
  test-suite case and pushed as `fix/starry-usercopy-cold-page`.
- The feedback loop is now seconds to about one minute for the next blocker,
  not a blind multi-hour wait.
- The current first OS blocker is narrower:
  `prepare_user_memory` waits for the address-space mutex while `sys_munmap`
  owns it. The next step is to add a tiny `mmap/munmap + syscall user-buffer`
  reproducer or extra caller logging before changing lock semantics.

Rootfs check after forced panic exit:

```text
e2fsck -fn .guest-runs/riscv64-m6-bench/rootfs-bench-usercopy-run.img
clean, 70290/1048576 files, 900480/4194304 blocks
```

PR state:

```text
branch: fix/starry-usercopy-cold-page
head: 179aef0fd fix(starry): prepopulate user strings before read
push: done to yks23/tgoskits
PR create: blocked locally by GitHub API/keyring connectivity
```

## 2026-05-21 Host-QEMU Verbose Ext4 Recheck

Goal: open the real guest cargo output without Docker overhead, and determine
why the 8-HART MTTCG ext4 run failed after reaching `starry-kernel`.

Control variables:

```text
QEMU: host /opt/homebrew/bin/qemu-system-riscv64
kernel: .guest-runs/riscv64-m6-bench/starry-smp8-maxcpu8-4g-futex-hwprobe-20260521.bin
qemu args: -smp 8 -m 4G -accel tcg,thread=multi -snapshot
rootfs original: .guest-runs/rootfs-selfbuild-full-smp8-ext4-j4-hwprobe-20260521.img
rootfs checked copy: .guest-runs/rootfs-selfbuild-full-smp8-ext4-j4-hwprobe-20260521.fsck.img
guest cargo: CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 M6_FORCE_REBUILD_KERNEL=1
```

Short feedback result:

- Replaying directly from the guest shell with `M6_CARGO_VV=1` reproduced the
  previous hidden cargo failure in about 26 seconds.
- The captured panic was inside `lwext4_rust::Ext4Filesystem::create()`:
  directory creation saw `child.nlink() == 3` while the wrapper asserted `2`.
- Host `e2fsck -fy` on a copy repaired many stale entries and bitmap/count
  inconsistencies under `.m6-ext4-target`; a second `e2fsck -fn` reported the
  checked copy clean.
- Replaying the same command on the fsck-clean copy passed the 26-second panic
  point and entered real rustc work. At 22:38 CST it was still alive in
  `starry-kernel-lib`, compiling through `ax-percpu`, `ax-config-macros`,
  `heapless`, `cfg-if`, and `winnow v1.0.3`; no `panic`, `FATAL`, or
  `error: could not compile` marker had appeared in the replay log.

High-signal issues observed:

- `getconf _NPROCESSORS_ONLN` reports `nproc=2` even though QEMU/OpenSBI boots
  8 HARTs. Manual `CARGO_BUILD_JOBS=4` bypasses this, but OS CPU topology
  exposure still needs a focused fix.
- `exit robust list failed: AxErrorKind::BadAddress` is still emitted during
  many rustc child exits. It is non-fatal here, but it is log noise and should
  be handled as bad robust-list-head tolerance. A local kernel patch and
  `test-futex-robust-list` case now cover this as a focused OS PR candidate.
- Cargo prints `database or disk is full` for last-use tracking even though the
  ext4 image has free space. The checked image contains an empty
  `m6-cargo-home/.global-cache` file, so the next formal run should clear or
  disable this cargo cache database path before starting.

Evidence:

```text
过程记录/早期记录/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j4-verbose-kernel-panicfull-20260521.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j4-verbose-kernel-afterfsck-run2-20260521.log
```

## 2026-05-22 8-HART M6 Pass2 Self-Build Closed

Goal: produce a StarryOS kernel binary from inside a StarryOS guest while the
guest is booted as an 8-HART system, then boot-test the produced binary.

Control variables:

```text
QEMU: host /opt/homebrew/bin/qemu-system-riscv64
boot kernel for build:
  .guest-runs/riscv64-m6-bench/starry-smp8-maxcpu8-4g-futex-hwprobe-20260521.bin
rootfs:
  .guest-runs/rootfs-selfbuild-full-smp8-ext4-pass2-serial-20260522.img
qemu args:
  -smp 8 -m 4G -accel tcg,thread=multi
guest cargo:
  CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 CARGO_INCREMENTAL=0
target dir:
  /opt/tgoskits/.m6-ext4-target
```

Result:

- The guest boot reported `Platform HART Count : 8` and StarryOS reported
  `smp = 8`.
- The final `starryos` pass2 cargo build completed successfully:
  `Finished release profile [optimized] target(s) in 131m 02s`.
- The guest printed `===M6-SELFBUILD-PASS===` and emitted the final ELF through
  the serial artifact path.
- Extracted artifact:
  `.guest-runs/riscv64-m6/starry-guest-smp8-pass2-serial-mttcg-j1.elf`
- Extracted boot binary:
  `.guest-runs/riscv64-m6/starry-guest-smp8-pass2-serial-mttcg-j1.bin`
- ELF SHA-256:
  `65336ca8cab8a9997636c2dc82717de2d572a59f9d11605cb6182d6659d10a07`
- Binary SHA-256:
  `02368b55258bdb7451e2d632628e74401e407c096ad6f10c9746f5b6fb76f998`

Boot smoke for the guest-built kernel:

```text
kernel:
  .guest-runs/riscv64-m6/starry-guest-smp8-pass2-serial-mttcg-j1.bin
rootfs:
  .guest-runs/rootfs-selfbuild-full-smp8-ext4-boot-smoke-20260522.img
qemu args:
  -smp 8 -m 4G -accel tcg,thread=single -snapshot
result:
  Platform HART Count : 8
  smp = 8
  ===BOOT-SMOKE-PASS===
```

Why the final artifact was extracted over serial:

- A previous long run reached `starry-kernel lib` after about 188 minutes, but
  the guest shell later segfaulted and the forced QEMU termination left the
  ext4 image dirty. Host `e2fsck` repaired the image, but the final target
  contents could not be trusted as the source of truth.
- The successful run therefore used a serial artifact marker and SHA-256 check
  to move the produced ELF out of the guest before terminating QEMU. The
  extracted ELF was then converted to a raw boot binary and boot-smoked on a
  separate fsck-clean rootfs copy.

Remaining boundary:

- This is an 8-HART StarryOS self-build result, but cargo was deliberately kept
  at `CARGO_BUILD_JOBS=1` and `RAYON_NUM_THREADS=1` to avoid mixing the final
  product milestone with the still-open multi-job kernel/TCG issues.
- True cargo `-j8` speedup still needs a separate validation lane after fixing
  the CPU topology exposure (`nproc` underreporting), robust futex cleanup
  noise, and dirty-ext4 feedback loop.

Evidence:

```text
过程记录/早期记录/multi-cpu/logs/m6-smp8-full-ext4-pass2-serial-mttcg-j1-20260522.log
过程记录/早期记录/multi-cpu/logs/boot-guest-built-smp8-smoke-pass-20260522.log
```

## 2026-05-22 Acceleration Evidence Recheck

Goal: move from "8 HART can build" to "8 HART can build faster", while keeping
short feedback loops separate from the multi-hour M6 path.

Fresh raw CPU benchmark with the guest-built kernel:

```text
kernel:
  .guest-runs/riscv64-m6/starry-guest-smp8-pass2-serial-mttcg-j1.bin
rootfs:
  .guest-runs/riscv64-m6-bench/rootfs-bench-run.img
qemu common:
  -smp 8 -m 4G -snapshot
only variable:
  -accel tcg,thread=single vs -accel tcg,thread=multi
```

| workers | single TCG us | multi TCG us | speedup |
| --- | ---: | ---: | ---: |
| 1 | 987073 | 795195 | 1.24x |
| 2 | 778295 | 501100 | 1.55x |
| 4 | 769171 | 297609 | 2.58x |
| 8 | 764731 | 310878 | 2.46x |

This confirms that the latest guest-built kernel still exposes real MTTCG
parallel speedup. The best older controlled raw benchmark remains `3.17x` at
4-HART/8-worker. The new 8-HART run is lower, which means simply raising
`-smp` is not enough; scheduler/wait/exit and QEMU host scheduling overheads
still matter.

Real M6 cargo-stage speed signal:

| lane | config | `starry-kernel lib` time | result |
| --- | --- | ---: | --- |
| serial | `SMP=8 thread=multi jobs=1` | `187m44s` | lib passed |
| parallel | `SMP=8 thread=multi jobs=4` | `84m16s` | lib passed, later pass1 segfault |

This is a `2.23x` speedup on a real StarryOS cargo stage. It is not yet a full
M6 acceleration pass because the `jobs=4` lane later hit a guest
cargo/rustc `Segmentation fault` during pass1.

Topology check with the guest-built kernel:

```text
Platform HART Count : 8
smp = 8
nproc = 8
getconf _NPROCESSORS_ONLN = 8
/proc/cpuinfo processor count = 8
/proc/stat cpuN count = 8
```

Next blocker:

- Keep `SMP=8 + jobs=1` as the product baseline.
- Use `jobs=4` for speed experiments, but reduce the pass1 segfault to a
  smaller OS regression before claiming full M6 acceleration.
- The robust-list bad-head tolerance patch is in the local tgoskits branch and
  should reduce noisy thread-exit cleanup failures from rustc/pthread exits.

Evidence:

```text
过程记录/早期记录/multi-cpu/logs/speed-rawcpu-guestbuilt-smp8-single-20260522.log
过程记录/早期记录/multi-cpu/logs/speed-rawcpu-guestbuilt-smp8-multi-20260522.log
过程记录/早期记录/multi-cpu/logs/topology-guest-built-smp8-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j1-serial-artifact-pexpect-20260522.log
过程记录/早期记录/multi-cpu/logs/m6-smp8-full-ext4-mttcg-j4-verbose-kernel-afterfsck-run2-20260521.log
```
