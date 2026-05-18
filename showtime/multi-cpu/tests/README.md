# Multi CPU Tests

多 CPU 测试要同时覆盖性能和正确性，但两者结论分开记录。

## 测试类别

1. speed benchmark
   - hello-world cargo build
   - medium cargo workspace
   - M6 selfbuild subset
2. kernel concurrency regression
   - futex private/shared
   - mutex lock/unlock stress
   - clone/thread/fork stress
   - shm/timerfd/futex mixed stress
3. correctness guard
   - `-accel tcg,thread=single`
   - real hardware or correct emulator, when available

## 记录要求

每个测试都需要记录：

- CPU count
- QEMU accel mode
- cargo jobs / rayon threads
- wall time
- pass/fail
- panic/trap/SIGSEGV
- binary checksum

