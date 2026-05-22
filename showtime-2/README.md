# Showtime 2 PR 汇报索引

本目录只整理本轮 TGOSKit / StarryOS 已提 PR 的汇报材料，重点展示每个 PR 对应的 OS 行为问题、根因、修复范围、测试证据和当前状态。它不包含实验日志、临时脚本或 showtime 旧目录内容。

## 快速结论

| PR | 标题 | 领域 | 当前状态 | 汇报重点 |
| --- | --- | --- | --- | --- |
| [#692](https://github.com/rcore-os/tgoskits/pull/692) | `fix(starry): tolerate robust futex cleanup faults` | StarryOS 线程退出 / futex ABI | MERGED，2026-05-19 合入 `dev` | 用户态 robust-list 坏指针不能拖垮内核退出清理路径。 |
| [#693](https://github.com/rcore-os/tgoskits/pull/693) | `fix(starry): preserve vfork parent blocking` | StarryOS clone/vfork 语义 | UPDATED OPEN，新 CI 运行中 | `CLONE_VFORK` 即使带 private child stack 也必须保持 Linux-compatible 父进程阻塞顺序。 |
| [#694](https://github.com/rcore-os/tgoskits/pull/694) | `fix(starry): support v4-mapped IPv6 sockets` | StarryOS socket ABI | MERGED，2026-05-18 合入 | IPv4-mapped IPv6 socket 要走 IPv4 backend，同时保持 IPv6 用户态 sockaddr 语义。 |
| [#695](https://github.com/rcore-os/tgoskits/pull/695) | `fix(rsext4): reuse uninit inode bitmaps` | rsext4 文件系统分配器 | MERGED，2026-05-18 合入 | ext4 未初始化 inode bitmap 不能让 allocator 跳过可用 inode 容量。 |
| [#842](https://github.com/rcore-os/tgoskits/pull/842) | `fix(starry): expose SMP CPU topology in sysfs` | StarryOS SMP topology ABI | READY OPEN，CI 20 pass / 0 fail | 让 guest 用户态正确看到 online CPU 数，支撑 cargo jobs/nproc 判断。 |
| [#843](https://github.com/rcore-os/tgoskits/pull/843) | `fix(starry): implement conservative riscv hwprobe` | StarryOS RISC-V syscall ABI | READY OPEN，CI 20 pass / 0 fail | 消除 Rust/RISC-V 用户态反复 `riscv_hwprobe` ENOSYS 噪音，保守暴露硬件能力。 |
| [#844](https://github.com/rcore-os/tgoskits/pull/844) | `test(starry): regress tmpfs rename exec ELF` | StarryOS tmpfs / exec regression | READY OPEN，CI 20 pass / 0 fail | 固化 tmpfs ELF copy -> rename -> readback -> exec 的文件系统回归。 |
| [#878](https://github.com/rcore-os/tgoskits/pull/878) | `fix(starry): avoid teardown usercopy from kernel tasks` | StarryOS teardown / usercopy / futex | READY OPEN，merge state CLEAN | 退出清理不能从 kernel task 上下文假设当前任务就是用户线程。 |
| [#879](https://github.com/rcore-os/tgoskits/pull/879) | `fix(axsync): release raw mutex before waking waiter` | axsync RawMutex / SMP 同步 | READY OPEN，merge state CLEAN | SMP mutex unlock 不能把 owner 直接 handoff 给尚未真正拿锁的 waiter。 |

## 讲述顺序建议

1. 先讲 #692、#878：它们都围绕线程退出、robust futex、`clear_child_tid` 和 usercopy 上下文边界，能说明 M6 cargo 压力暴露的是内核退出清理语义问题。
2. 再讲 #842、#843、#879：分别对应多核可见性、RISC-V ABI 降噪和 SMP mutex 语义，是多核 cargo 压力下最相关的三块内核支撑。
3. 接着讲 #693、#694：它们是用户态兼容 ABI 修复，分别覆盖 clone/vfork 和 IPv6 socket。
4. 最后讲 #695、#844：把 self-build 过程中对文件系统可靠性的关注落到 ext4 inode allocator 和 tmpfs renamed-ELF regression。

完整逐项材料见 [pr-report.md](/Users/txc/code/Auto-OS/showtime-2/pr-report.md)。

8 核 M6 cargo 进展见 [m6-8core-status.md](/Users/txc/code/Auto-OS/showtime-2/m6-8core-status.md)。

## 信息来源

- `/Users/txc/code/Auto-OS/success-pr/PR-TRACKING.md`
- `/Users/txc/code/Auto-OS/success-pr/pr-draft-starry-teardown-usercopy-futex.md`
- `/Users/txc/code/Auto-OS/success-pr/pr-draft-axsync-rawmutex-competitive-wakeup.md`
- `/Users/txc/code/Auto-OS/success-pr/pr-draft-robust-futex-bad-head.md`
- `/Users/txc/code/Auto-OS/success-pr/pr-694.txt`
- `/Users/txc/code/Auto-OS/success-pr/pr-695.txt`
- `/Users/txc/code/Auto-OS/showtime/presentation/talk-track.md`
- `gh pr view` / `gh pr checks` 查询到的 PR 元数据
