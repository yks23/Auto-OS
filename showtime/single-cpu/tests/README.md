# Single CPU Tests

本目录记录单 CPU baseline 和相关 bugfix PR 的测例。原则是每个 bug 都能对应到一个可运行 case，避免 PR 只靠现象描述。

## 测试层次

1. Smoke boot: StarryOS 能在 `-smp 1` QEMU 下启动。
2. Syscall regression: futex、clone/vfork、socket 等单点行为。
3. App-level smoke: busybox/shell/小程序能正常运行。
4. PR-specific minimal case: 每个 PR 对应一个最小复现。

## 当前重点

- `test-futex-robust-list`
- `test-vfork`
- `bug-af-inet6-v4mapped`
- rsext4 inode bitmap regression, TODO

