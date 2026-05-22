# Multi CPU PR Candidates

这些是可能从多核实验中拆出来的 PR 候选。当前都还需要更小测例和更多验证。

## P1. FUTEX_PRIVATE_FLAG support

- area: StarryOS futex syscall
- motivation: userspace pthread/Rust runtime 常用 private futex；缺失 private key 语义可能影响多线程 wake/wait。
- current status: 实验改动已在 private worktree 中验证过 hello-world build。
- needed tests:
  - private futex wait/wake
  - shared futex wait/wake
  - private/shared 不互相串扰
  - pthread mutex/condvar smoke

## P2. Mutex unlock ordering

- area: `axsync::Mutex`
- motivation: SMP 下 unlock/wake ordering 影响 waiter 是否能稳定观察 unlocked 状态。
- current status: 实验改动为先释放锁状态再 notify waiter。
- needed tests:
  - 多线程 lock/unlock stress
  - cargo build workload
  - timer/futex 组合压力

## P3. SMP guest cargo build test

- area: test-suit/showtime
- motivation: 需要一个比 hello-world 更接近实际 selfbuild 的并行 build regression。
- current status: 尚未形成 PR 测例。
- needed tests:
  - 小 workspace, `-j1` vs `-j4`
  - 中等 workspace, 重复多次
  - panic/trap 自动抓取

## P4. QEMU TCG documentation

- area: docs/runbook
- motivation: 避免把 RISC-V MTTCG speed run 误读成 correctness proof。
- current status: showtime 文档已先记录。
- needed tests:
  - 不需要代码测例，但需要引用实际 run logs。

