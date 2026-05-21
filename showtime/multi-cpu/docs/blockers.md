# Multi CPU Blockers

## B1. QEMU RISC-V MTTCG LR/SC correctness

- severity: high for correctness, medium for speed experiment
- symptom: RISC-V QEMU TCG 多线程模式下，跨 hart LR/SC reservation invalidation 建模不正确。
- impact: guest userspace atomic CAS 可能错误成功，Rust build 这类高度依赖原子的 workload 可能被破坏。
- mitigation:
  - correctness run 用 `-accel tcg,thread=single`
  - speed experiment 可以跑 `-accel tcg,thread=multi`，但必须标注风险
  - 最终正确性应在真硬件或正确模拟器上确认

## B2. guest cargo build 重 I/O 和并发压力

- severity: high
- symptom: 大型 guest cargo build 曾需要 `CARGO_BUILD_JOBS=1`、`RAYON_NUM_THREADS=1` 来绕开 SMP 内核 page fault/重 I/O 问题。
- impact: M6 selfbuild 不能只看 hello-world，小 workload 过了不代表 selfbuild 过。
- next:
  - 先从 hello-world 多轮 benchmark 扩到中等 workspace。
  - 再回到 M6 selfbuild。
  - 每个 panic/trap 都要保存完整 log。

## B3. futex private/shared key

- severity: medium/high
- symptom: 多线程 userspace runtime 会大量使用 futex，private futex 和 shared futex 的 key 语义不清会造成 wake miss 或错误共享。
- experiment: 支持 `FUTEX_PRIVATE_FLAG`。
- next:
  - 写 futex private/shared regression。
  - 验证 pthread/cargo workload。

## B4. mutex unlock wakeup ordering

- severity: medium/high
- symptom: unlock 时如果 owner handoff 和 wake 顺序不合理，可能造成 waiter 看到状态不一致或丢 wake。
- experiment: unlock 先 store unlocked，再 notify one waiter。
- latest evidence:
  - v27 在 `SMP=4 + thread=single + jobs=2` 的 `quote v1.0.45` 阶段 panic：
    `Thread(76) tried to acquire mutex it already owns at os/StarryOS/kernel/src/task/user.rs:38:52`。
  - 该调用点是用户态 page fault 分支重新获取 process address-space mutex。
  - v28 改成竞争式 unlock 后已经越过 v27 的 `quote` build-script panic 点，继续进入 `quote`/`syn` rustc 编译。
- next:
  - 写内核/用户态压力测例。
  - 对比单核、多核、MTTCG 和 `thread=single`。

## B5. benchmark 证据不足

- severity: medium
- symptom: 目前 hello-world 只有一组初始数据。
- next:
  - 每个配置至少 5 次。
  - 记录 raw CSV。
  - 区分 cold build、incremental build、cache 命中情况。

## B6. SMP4 M6 early allocation panic

- severity: high
- symptom: 完整 M6 `-smp 4 -accel tcg,thread=multi CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4` 在约 13 秒内失败，日志显示 Rust allocation panic：

```text
memory allocation of 8912904 bytes failed
```

- evidence:
  - `showtime/multi-cpu/logs/m6-smp4-mttcg-j4.log`
  - `showtime/multi-cpu/logs/m6-smp4-mttcg-j4.done`
- impact: 当前还不能进入 M6 full cargo 编译阶段，因此不能讨论 4 核 M6 full build speedup。
- next:
  - 用 `M6_TCG_THREAD=single` + `--subset` 跑同样 `-smp 4/jobs=4`，先判断是否 MTTCG 特有。
  - 如 thread-single 也失败，继续缩小到 one-crate 或 toolchain sanity 阶段，定位是 StarryOS SMP 内存分配、tmpfs、还是 rust runtime 初始化压力。
  - 如 thread-single 通过，再把 MTTCG 风险单独标成 speed-only blocker。

## B7. SMP guest parallel user workload segfault

- severity: high
- symptom: 在当前 `origin/dev` 基线的 SMP StarryOS guest 中，短 SHA-only
  benchmark 呈现 `sha_jobs=1` 通过、`sha_jobs=2/4` 触发
  `Segmentation fault (core dumped)`。
- evidence:
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-sha1-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-sha2-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-sha4-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-dd1-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-dd2-20260520.log`
- isolation: 强制 `M6_BENCH_WORKLOAD=dd` 后，单 worker 通过，双 worker
  仍 segfault，因此不是 `sha256sum` 或 hash 管道特有。
- latest isolation:
  - `/dev/zero` 单次大读和 `/dev/null` 单次大写原先会受 direct I/O
    内部 2048-byte buffer 影响；该层已通过 direct VFS full-transfer 修复。
  - 新 `test-dev-zero-full-transfer` 在 `SMP=4, TCG=single` 下 PASS。
  - `dd & dd & wait` 直接后台运行 PASS，两个 wait 状态都是 0。
  - `run_work_unit(){ dd ...; }; ( run_work_unit ) &` 形式仍异常：
    函数内部 `ddrc=0`，kernel info log 也显示 subshell task `exit with code: 0`，
    但父 Bash 的 `wait` 可得到 124。
- impact: 不能直接宣称多核 guest cargo build 加速；必须先让并发用户态进程在
  SMP kernel 下稳定。
- next:
  - 将 Bash 后台 subshell 的 wait 状态异常收缩成 C 回归：父进程 wait
    两个中间子进程，中间子进程再 fork/exec `dd` 并 wait，期望父进程看到
    两个中间子进程均以 0 退出。
  - 对照 Bash 版本保留为系统测试，C 版本用于精确定位内核 wait/exit 语义。
  - 保持 QEMU 正确性模式 `-accel tcg,thread=single`，MTTCG 只作为 speed
    signal。

## B8. fork+exec wait path still reaches atomic-context sleep

- severity: high
- symptom: 给 `sys_waitpid` 增加 check/register/check 后，纯 fork 子进程
  `_exit(0)` 的 wait 压测通过；但 fork 后 exec `/bin/true` 的压测在
  round 128 之后触发内核 panic：

```text
panicked at os/arceos/modules/axtask/src/wait_queue.rs:91:9:
sleeping or rescheduling is not allowed in atomic context: irq_enabled=false, preempt_count=0
```

- evidence:
  - `showtime/multi-cpu/logs/waitpid-child-exit-wakeup-fixed-20260520.log`
  - `showtime/multi-cpu/logs/waitpid-child-exit-wakeup-exec-waitfix-20260520.log`
  - `showtime/multi-cpu/logs/shellcase-function-true-waitfix-20260520.log`
- impact: 说明当前 wait 修复只覆盖 lost-wakeup 子问题，不能作为完整的
  Bash/fork+exec/SMP 并发修复提交。
- next:
  - 保留 fork+exec C 回归作为主复现，避免 Bash 语义噪声。
  - 在 `TaskInner::join` / `WaitQueue::wait_until` / init task join 路径
    增加最小 caller/state 诊断，确认是谁在 IRQ-disabled 且 preempt_count=0
    的状态下尝试睡眠。
  - 确认是否存在 guard 释放后 IRQ 状态未恢复、init 进程异常退出后 main
    join 路径恢复状态错误、或 exec 资源释放路径破坏调度状态。

## B9. M6 SMP cargo hits contended RawMutex wait in atomic context

- severity: high
- symptom: `SMP=4 + tcg,thread=single + CARGO_BUILD_JOBS=2` 的 M6 resume3
  已进入真实 `starry-kernel-lib` 编译，在 `ax-percpu` / `ax-percpu-macros`
  附近触发内核 panic：

```text
panicked at os/arceos/modules/axsync/src/mutex.rs:78:26:
sleeping or rescheduling is not allowed in atomic context:
irq_enabled=false, preempt_count=0,
caller=os/arceos/modules/axsync/src/mutex.rs:78:26
```

- evidence:
  - `showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-directcargo-resume3-panic-capture-20260521.log`
- interpretation:
  - 这不是单纯的日志缺失，也不是 MTTCG 的 LR/SC 问题；该轮使用
    `tcg,thread=single`。
  - 当前诊断内核已经包含 RawMutex unlock-before-wake，因此越过了之前的
    mutex self-owner panic。
  - 新 panic 表示某个 OS 路径在 IRQ disabled 状态下竞争阻塞 mutex，并准备
    睡眠等待；真正修复需要定位外层 caller。
- next:
  - 增量构建 caller-aware RawMutex 诊断 kernel。
  - 用 fsck-clean rootfs resume，捕获外层锁调用点。
  - 确认调用点后拆 PR：如果是该路径必须在 atomic context 运行，则改成
    non-sleeping lock；如果是不该关 IRQ，则把锁/等待移出 atomic 区域。

## B9. cargo -j2 ppoll path can fault the SMP kernel

- status: first layer fixed in `/private/tmp/tgoskits-dev-local`
- severity: high
- symptom: 在 `SMP=4 + tcg,thread=single` 下，synthetic native cargo smoke
  可以稳定验证控制变量：
  - `sha_jobs=1, cargo_jobs=1`: PASS
  - `sha_jobs=1, cargo_jobs=2`: FAIL, kernel Supervisor Page Fault
  - `sha_jobs=2, cargo_jobs=2`: FAIL, `BENCH-CARGO-FAIL rc=139`
- evidence:
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j1-pass-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-j2-fail-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-fail-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-summary-fail-20260520.txt`
- isolation:
  - 修正脚本后，`M6_BENCH_CARGO_JOBS=2` 已真正传入 `cargo build -j2`。
  - 失败发生在 cargo 同时编译两个 synthetic leaf crate 后，内核在
    `starry_kernel::syscall::io_mpx::poll::do_poll` 的 `pollfd.revents`
    更新路径触发 supervisor write page fault。
  - fault address 是低用户地址 `0x40f0b96`，说明 `ppoll`/poll 回调中
    用到的结果缓冲或索引在阻塞/唤醒后出现了错误地址语义。
  - 二 worker dd 后的 `rc=139` 仍保留为另一个短反馈形状，但 cargo
    `-j2` 已经足够单独复现核心 SMP 并发问题。
- fix:
  - `sys_poll`/`sys_ppoll` now copy the user `pollfd` array into kernel memory
    before blocking.
  - The polling closure updates the kernel copy only; `revents` are written
    back after `do_poll` returns.
  - Added `test-ppoll-user-buffer` to cover the blocking wakeup and `revents`
    writeback behavior.
- validation:
  - `SMP=4, tcg,thread=single, sha_jobs=1, cargo_jobs=2, foreground cargo`:
    PASS, host wall 195s, `===BENCH-DONE===`.
- evidence after fix:
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-pass-20260520.log`
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-summary-pass-20260520.txt`
- impact: cargo `-j2` can now complete in the correctness baseline. Full
  multi-core speedup is still not proven because `tcg,thread=single` serializes
  host execution.
- next:
  - Run the new `test-ppoll-user-buffer` through the test-suite runner before
    PR.
  - Split the init hook and benchmark foreground mode out of the OS PR; they
    are experiment harness changes only.
  - Track the background cargo `wait "$cargo_pid"` missing-`BENCH-DONE` as a
    separate process/wait cleanup issue.
  - 保持 `tcg,thread=single` 作为 correctness baseline；MTTCG 只做 speed signal。

## B10. background cargo wait misses benchmark completion marker

- severity: medium/high for automation, lower for cargo correctness
- symptom: With the ppoll fix, background cargo plus heartbeat reaches
  `Finished release profile [optimized]`, but the guest does not print
  `===BENCH-CARGO ...===` or `===BENCH-DONE===` after `wait "$cargo_pid"`.
- evidence:
  - `showtime/multi-cpu/logs/bench-smp4-threadsingle-cargo-synthetic-native-sha1-cargoj2-ppollfix-pass-20260520.log`
- isolation:
  - Foreground cargo with the same kernel, rootfs, `SMP=4`,
    `tcg,thread=single`, and `cargo_jobs=2` prints `BENCH-DONE`.
  - Therefore the compiler workload is now stable; the remaining issue is the
    shell/background wait/exit-status path used by the heartbeat harness.
- next:
  - Reduce to a C testcase: parent starts a long child, polls status, waits,
    then must continue executing and print a marker.
  - Keep foreground cargo as the short correctness proof while debugging this
    separate wait-path issue.

## B11. user-copy cold anonymous pages can fault in the wrong context

- status: PR branch prepared and pushed
- severity: high for syscall robustness, relevant to SMP/M6 stability
- branch: `fix/starry-usercopy-cold-page`
- head commit: `179aef0fd fix(starry): prepopulate user strings before read`
- symptom:
  - `vm_read_slice` / `vm_write_slice` could execute `user_copy` against a
    valid but untouched anonymous user page.
  - null-terminated user strings could be read byte-by-byte from a valid but
    untouched anonymous user page.
  - That can fault in S-mode and enter the page-fault path with IRQs disabled.
  - The fault path may need the process address-space mutex, which is not safe
    as a sleeping lock in an IRQ-off path.
- fix:
  - Pre-populate slice user pages in normal syscall context.
  - Pre-populate each user-string page before the volatile byte read.
  - Then run `user_copy` as a no-fault copy; remaining faults are converted to
    `EFAULT` through the exception fixup path.
- test-suite:
  - `test-suit/starryos/normal/qemu-smp1/bugfix/bug-usercopy-cold-page`
  - Case writes into untouched anonymous pages through `getcwd` and
    `/dev/zero` `read`, and reads an empty path from an untouched anonymous
    page through `open`.
- evidence:
  - `cargo fmt`
  - `cargo fmt --check`
  - `git diff --check upstream/dev`
  - host C syntax smoke for the new test case
- blocked validation:
  - `cargo test -p axbuild ...` and `cargo xtask ... -l` are blocked locally
    by crates.io/DNS transfer failures.
  - Docker fallback is blocked by Docker API 500.
  - `gh pr create` is blocked by `api.github.com` connection failure.

## B12. M6 fork/clone aspace lock can block user-memory fault handling

- status: diagnosed; first mitigation folded into B11 PR branch
- severity: high for SMP guest cargo build
- evidence:
  - `showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-mutexowner-resume-20260521.log`
- configuration:
  - kernel: `.guest-runs/riscv64-m6-bench/starry-platformdiag-mutexowner-20260521.bin`
  - qemu: `-smp 4 -m 4G -accel tcg,thread=single`
  - guest cargo: `CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2`
- symptom:

```text
Compiling lock_api v0.4.14
panicked at os/StarryOS/kernel/src/mm/access.rs:269:10:
RawMutex would block in atomic context:
waiter=os/StarryOS/kernel/src/mm/access.rs:269:10
owner_task=1066
owner=os/StarryOS/kernel/src/syscall/task/clone.rs:204:55
```

- interpretation:
  - One task was in the user-memory page-fault handler and needed the process
    address-space lock while IRQs were disabled.
  - Another task owned the same address-space lock while cloning/forking the
    process address space.
  - The immediate OS rule is that normal syscall user-memory access should not
    rely on trap-time page population.
- mitigation in progress:
  - `fix/starry-usercopy-cold-page` pre-populates slice user buffers and
    null-terminated user string pages before touching them.
  - The next M6 rerun should keep the same rootfs/QEMU/cargo variables and only
    replace the kernel with a build containing that branch.
- remaining risk:
  - If another path still intentionally touches unmapped user memory directly,
    it may need the same pre-populate/no-fault treatment or a focused
    `try_lock`/`EFAULT` policy.

## B13. M6 munmap/aspace lock can block user-memory prepopulate

- status: new first blocker after applying the user-copy PR shape in the
  diagnostic kernel
- severity: high for SMP guest cargo build
- evidence:
  - `showtime/multi-cpu/logs/m6-smp4-j2-platformdiag-usercopy-ownerguard-resume-20260521.log`
- configuration:
  - kernel:
    `.guest-runs/riscv64-m6-bench/starry-platformdiag-usercopy-ownerguard-20260521.bin`
  - rootfs:
    `.guest-runs/riscv64-m6-bench/rootfs-bench-usercopy-run.img`
  - qemu: `-smp 4 -m 4G -accel tcg,thread=single`
  - guest cargo: `CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2`
- symptom:

```text
Compiling compiler_builtins v0.1.160
Compiling core v0.0.0
Compiling proc-macro2 v1.0.106
panicked at os/StarryOS/kernel/src/mm/access.rs:311:33:
RawMutex would block in atomic context:
waiter=os/StarryOS/kernel/src/mm/access.rs:311:33
owner_task=128
owner=os/StarryOS/kernel/src/syscall/mm/mmap.rs:276:56
```

- interpretation:
  - The user-copy cold-page fix moved the run past the previous `clone.rs`
    owner blocker.
  - The current waiter is `prepare_user_memory`, and the owner is
    `sys_munmap` holding the process address-space mutex while unmapping.
  - This is an OS-level synchronization/VM interaction issue, not a Docker or
    MTTCG artifact: the run uses QEMU `tcg,thread=single`.
- shortest next feedback:
  - Build a focused test that runs one thread/process through repeated
    `mmap`/`munmap` while another issues syscalls that copy to/from user
    buffers, then verify the kernel returns normal syscall errors or progress
    instead of panicking.
  - If the testcase is still too noisy, add a diagnostic log at
    `prepare_user_memory` and `sys_munmap` recording current task id, syscall
    id if available, IRQ state, range, and owner location.
- fix direction:
  - Do not make `RawMutex` sleep in atomic context.
  - Either ensure user-memory prepopulate cannot run while IRQs are disabled,
    or narrow/reshape `sys_munmap` address-space locking so normal user-copy
    prepopulate does not block in an atomic path.
- PR rule:
  - Once the reproducer or exact caller pair is stable, split it from the
    user-copy PR and prepare a separate TGOSKit PR with a focused test-suite
    case.
