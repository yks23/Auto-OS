# Showtime 2 PR 汇报

更新时间：2026-05-23（Asia/Shanghai）

## 总览

这组 PR 的共同点是：它们都不是为了让某个 demo 脚本绕过去，而是在补 StarryOS / TGOSKit 面对真实 Linux/Rust/Cargo workload 时需要具备的 OS 行为。覆盖面包括线程退出清理、futex ABI、clone/vfork 兼容、socket 地址族语义、文件系统 inode 分配和 SMP blocking mutex。

| PR | 状态 | CI / merge 信息 | 测试证据 | OS 层意义 |
| --- | --- | --- | --- | --- |
| [#692](https://github.com/rcore-os/tgoskits/pull/692) | MERGED | `gh pr view`：2026-05-19 合入，base `dev` | `test-futex-robust-list`；Linux 容器原生测例曾连续 3 次 `72 pass, 0 fail` | 修复线程退出时 robust futex cleanup 对用户坏指针的容错。 |
| [#693](https://github.com/rcore-os/tgoskits/pull/693) | UPDATED OPEN | 2026-05-23 CST 推送 `4503b5fb3`，标题/正文改为 `fix(starry): preserve vfork parent blocking`；run `26305672447` 中 riscv64/x86_64/aarch64 Starry QEMU、clippy、format、sync-lint 已过；仅 loongarch Starry QEMU fail，失败点是 `apk-curl` 网络下载 Alpine index 1200s timeout，非 vfork case；PR 仍是 `reviewDecision=CHANGES_REQUESTED` | `test-vfork`；`git diff --check` PASS；`cargo fmt --check` PASS；loongarch 非网络 suite 到 43/44，失败在网络 apk/curl | 恢复 Linux-compatible `CLONE_VFORK` 父进程阻塞语义，避免 busybox/sh/timeout 这类真实 workload 因同步顺序破坏而崩溃。 |
| [#694](https://github.com/rcore-os/tgoskits/pull/694) | MERGED | 归档记录：2026-05-18 合入；一次 `gh` 查询 EOF，状态以归档为准 | `bug-af-inet6-v4mapped`；x86_64 已过，其他旧架构结果需按日志/重跑确认 | 修复 AF_INET6 与 IPv4-mapped address 的用户态 socket ABI。 |
| [#695](https://github.com/rcore-os/tgoskits/pull/695) | MERGED | `gh pr view`：2026-05-18 合入；历史展示记录 CI 绿 | inode allocation regression 待进一步收窄；PR 已合入 | 修复 ext4 未初始化 inode bitmap 的 allocator 行为。 |
| [#842](https://github.com/rcore-os/tgoskits/pull/842) | READY OPEN | 2026-05-23 已执行 `gh pr ready`；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`；Actions 20 pass / 0 fail | qemu-smp4 topology regression；`cargo fmt --all -- --check` PASS | 修复 SMP CPU topology 对用户态的暴露，支撑 `nproc`、affinity 和 cargo 并行度判断。 |
| [#843](https://github.com/rcore-os/tgoskits/pull/843) | READY OPEN | 2026-05-23 已执行 `gh pr ready`；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`；Actions 20 pass / 0 fail | `qemu-smp1/bugfix/bug-riscv-hwprobe`；M6 integration kernel 运行中 `riscv_hwprobe=0` | 保守实现 RISC-V `riscv_hwprobe`，消除真实 Rust/Cargo workload 中的 ENOSYS 日志噪音。 |
| [#844](https://github.com/rcore-os/tgoskits/pull/844) | READY OPEN | 2026-05-23 已执行 `gh pr ready`；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`；Actions 20 pass / 0 fail | BusyBox tmpfs copy -> rename -> ELF magic -> exec regression；`sh -n busybox-tests.sh` PASS | 固化 tmpfs rename 后 ELF 读回和执行的文件系统行为。 |
| [#878](https://github.com/rcore-os/tgoskits/pull/878) | READY OPEN | `gh pr view`：`isDraft=false`，`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`；CI rollup 显示 container/qemu/self-hosted 相关 job 已通过，部分 host job skipped | `git diff --check upstream/dev...HEAD` PASS；`cargo fmt --check` PASS；现有 robust futex / mt-execve 覆盖 teardown ABI | 修复 teardown/usercopy/futex 对“当前上下文必是用户线程”的错误假设。 |
| [#879](https://github.com/rcore-os/tgoskits/pull/879) | READY OPEN | `gh pr view`：`isDraft=false`，`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`；CI rollup 显示 container/qemu/self-hosted 相关 job 已通过，部分 host job skipped | `git diff --check upstream/dev...HEAD` PASS；`cargo fmt --check` PASS；新增 `qemu-smp4/test-rawmutex-handoff` | 修复 SMP RawMutex owner handoff 竞态和 guard 跨任务释放风险。 |
| [#800](https://github.com/rcore-os/tgoskits/pull/800) | BLOCKED OPEN | 已在独立 worktree 重放到最新 `dev` 并推送 `6aeb2566e`；`mergeStateStatus` 从 DIRTY 变为 BLOCKED，冲突已消；`reviewDecision=CHANGES_REQUESTED`；CI run `26308003915` 中 format/sync-lint/std/clippy/ArceOS/axvisor 已过，主要等 Starry qemu container jobs | `cargo fmt` PASS；`cargo clippy -p ax-fs-ng --target riscv64gc-unknown-none-elf -- -D warnings` PASS；四架构 bugfix list PASS；test-suite 已迁到 `normal/qemu-smp1/bugfix/test-dev-zero-full-transfer` | 直接设备读写完整传输语义；剩余是旧 review 状态和 Starry CI pending，不再是 merge conflict。 |
| [#885](https://github.com/rcore-os/tgoskits/pull/885) | DRAFT OPEN | 2026-05-23 CST 新建 draft；branch `fix/starry-syscall-thread-snapshot`，commit `82fa8297d`；等待 Actions | `git diff --check` PASS；`cargo fmt --all --check` PASS；`cargo check -p starry-kernel --target riscv64gc-unknown-none-elf` PASS；`zig cc` C 语法 PASS；`test-openat-umask-smp --list` PASS | 文件创建 syscall 在入口固定用户线程上下文，避免 usercopy 后二次 `current().as_thread()` 读到错误 task；这是 M6 多核压力暴露出来的保守 OS hardening。 |

## #692 robust futex cleanup faults

**问题 / 根因**

线程退出时需要遍历 robust futex list 并处理 pending futex。旧路径把用户态 robust-list entry 或 pending entry 的坏地址当成清理失败，容易把用户态坏指针扩大成内核退出路径噪声或失败。

**修复内容**

- robust futex cleanup 对坏用户地址做容错处理。
- pending futex cleanup 独立覆盖，避免坏链表 entry 影响应当完成的 owner-death 清理。
- 测例按 Linux ABI 拆分，避免要求“坏 list head 后仍必须继续 pending cleanup”这种强于 Linux 的预期。

**测试 / 状态**

- PR：[#692](https://github.com/rcore-os/tgoskits/pull/692)
- 状态：已合入 `dev`，`gh pr view` 显示 `mergedAt=2026-05-19T09:15:00Z`。
- 证据：`test-futex-robust-list`；历史材料记录 Linux 容器原生编译运行连续 3 次 `72 pass, 0 fail`。

**为什么是 OS 层功能改动**

这是线程退出和 futex owner-death ABI 的语义修复。脚本无法替代内核在进程退出时正确处理用户态 robust-list 状态。

## #693 vfork child-stack clone

**问题 / 根因**

Linux `CLONE_VFORK` 语义要求父进程等到子进程 `exec` 或退出，即使调用者传了 private child stack。上一版 PR 把阻塞条件收窄为 `stack == 0`，破坏了 busybox / shell / timeout 依赖的父子同步顺序，riscv64 CI 中 busybox case 出现 userland SIGSEGV，最终 46/47 失败。

**修复内容**

- `clone.rs` 恢复为所有 `CLONE_VFORK` 都设置并等待 `vfork_done`。
- 继续使用 `PollSet` 保持等待可被任务 interrupt，不改变 exec/exit 唤醒路径。
- `test-vfork` 的 child-stack clone case 改成 Linux-compatible 期望：带 private child stack 也必须阻塞父进程。

**测试 / 状态**

- PR：[#693](https://github.com/rcore-os/tgoskits/pull/693)
- 状态：2026-05-23 CST 已推送修复 commit `4503b5fb3` 到现有 PR 分支，并更新 PR title/body；`gh pr view` 显示 run `26305672447` 中 riscv64/x86_64/aarch64 Starry QEMU、clippy、format、sync-lint 已通过，剩余失败是 `Test starry loongarch64 qemu / run_container` 的 `apk-curl` 网络下载 Alpine index 1200s timeout，review 仍为 `CHANGES_REQUESTED`。
- 前一轮阻塞点：run `26267901276` 中 `Test starry riscv64 qemu / run_container` 失败，busybox suite 输出 `46/47 case(s) passed`，失败 case 是 `busybox`，日志含 `busybox_arch` / `busybox_arp` / `Segmentation fault`。
- 本地证据：`git diff --check HEAD^..HEAD` PASS；`cargo fmt --check` PASS；macOS 上 `cargo xtask clippy --package starry-kernel` 被既有 `ax-percpu` / Mach-O section baseline 阻断，非本 patch 引入。
- 下一步：需要 maintainer/admin rerun failed loongarch job，或追加 no-op commit 触发新 CI；然后评论说明已恢复 Linux-compatible `CLONE_VFORK` 阻塞语义并请求 reviewer 重新检查 semantic blocker。

**为什么是 OS 层功能改动**

这是 process/thread 创建 ABI 的兼容性修复，影响 shell、`posix_spawn` 和 Rust/Cargo 子进程模型，不是调整启动脚本能解决的问题。

## #694 IPv4-mapped IPv6 socket

**问题 / 根因**

用户态可以在 AF_INET6 socket 上使用 `::ffff:127.0.0.1` 这类 IPv4-mapped IPv6 地址。内核内部需要走 IPv4 backend，但对 `bind/connect/accept/getsockname/getpeername` 暴露给用户态的仍应是 IPv6 sockaddr 语义。

**修复内容**

- 地址解析支持 IPv4-mapped IPv6。
- bind/connect 时把 mapped address 归一化到 IPv4 backend。
- accept / getsockname / getpeername 返回时包装成用户态期望的 IPv4-mapped IPv6 sockaddr。

**测试 / 状态**

- PR：[#694](https://github.com/rcore-os/tgoskits/pull/694)
- 状态：归档记录显示 `mergedAt=2026-05-18T16:05:51Z`；本次 `gh pr view` 有一次 GraphQL EOF，合入状态以本地归档为准。
- 测例：`bug-af-inet6-v4mapped`；历史材料记录 x86_64 已过，其他架构旧失败需要看日志或重跑确认。

**为什么是 OS 层功能改动**

这是 socket ABI 和地址族兼容行为。核心在内核网络层对 sockaddr 的解释和返回，不是用户态命令行参数修补。

## #695 rsext4 inode bitmap

**问题 / 根因**

ext4 block group 的 inode bitmap 可能处于未初始化状态。旧 allocator 如果直接跳过这类 group，会损失可用 inode 容量，并在更复杂的文件创建/读回场景里放大为文件系统可靠性问题。

**修复内容**

- 识别 uninit inode bitmap。
- 首次使用时初始化 bitmap。
- 初始化后继续从该 block group 分配 inode，同时保留已初始化 bitmap 的原扫描逻辑。

**测试 / 状态**

- PR：[#695](https://github.com/rcore-os/tgoskits/pull/695)
- 状态：已合入，`gh pr view` 显示 `mergedAt=2026-05-18T09:17:54Z`；历史展示记录 CI 绿。
- 测试：已有合入 CI；仍建议后续补一个更小的 rsext4 / axfs-ng inode allocation regression。

**为什么是 OS 层功能改动**

这是文件系统 allocator 正确性问题，影响 inode 分配和 ext4 元数据解释，不能通过构建脚本或 rootfs 临时处理替代。

## #842 SMP CPU topology exposure

**问题 / 根因**

SMP kernel 启动了多个 hart，但用户态通过 `/proc/cpuinfo`、`/sys/devices/system/cpu/online`、`sysconf` 或 affinity 查询时可能只能看到不完整 CPU topology。Cargo / build scripts 会用这些接口推断并行度，错误暴露会让 guest 以为只有少数 CPU 可用。

**修复内容**

- 补齐 StarryOS 的 CPU topology 暴露路径。
- 让 sysfs/procfs/sysconf/affinity 对 online CPU 数保持一致。
- 用 qemu-smp4 regression 覆盖用户态可见行为。

**测试 / 状态**

- PR：[#842](https://github.com/rcore-os/tgoskits/pull/842)
- 状态：READY OPEN；Actions 20 pass / 0 fail；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`。
- 证据：`cargo fmt --all -- --check` PASS；qemu-smp4 topology regression 覆盖 CPU online/affinity。

**为什么是 OS 层功能改动**

这是内核对 SMP topology 的 ABI 暴露，不是提高脚本里的 `-j` 数字。用户态只有看到正确 CPU 拓扑，才能合理选择并行度。

## #843 conservative riscv hwprobe

**问题 / 根因**

RISC-V Rust/Cargo 用户态会反复调用 `riscv_hwprobe` 查询 CPU/ISA 能力。旧内核没有实现该 syscall，导致长时间 M6 日志被 `Unimplemented syscall: riscv_hwprobe` 淹没，关键 panic/trap 信号不易定位。

**修复内容**

- 在 syscall 分发表接入 `riscv_hwprobe`。
- 实现保守语义：校验 flags、用户指针和未知 key，但不激进宣称硬件扩展能力。
- 用专门 bugfix case 覆盖正常 key、未知 key、非法 flags 和坏指针。

**测试 / 状态**

- PR：[#843](https://github.com/rcore-os/tgoskits/pull/843)
- 状态：READY OPEN；Actions 20 pass / 0 fail；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`。
- 证据：`qemu-smp1/bugfix/bug-riscv-hwprobe`；本轮 M6 integration kernel 的短跑统计显示 `riscv_hwprobe=0`。

**为什么是 OS 层功能改动**

这是 RISC-V Linux ABI 兼容 syscall。它不直接保证编译更快，但显著缩短信号提取链路，避免真实 workload 中的 syscall 噪音吞掉故障。

## #844 tmpfs rename exec ELF regression

**问题 / 根因**

tmpfs 上 copy 到临时路径、rename 到最终路径，再读取 ELF magic 并执行，是用户态安装器和测试脚本常见路径。曾经的 tmpfs rename/readback 问题可能让 renamed ELF 的元数据或文件内容不可执行。

**修复内容**

- 新增 BusyBox regression：tmpfs copy -> rename -> ELF magic readback -> exec。
- 测例聚焦文件系统行为，不把它写成脚本 workaround。

**测试 / 状态**

- PR：[#844](https://github.com/rcore-os/tgoskits/pull/844)
- 状态：READY OPEN；Actions 20 pass / 0 fail；`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`。
- 证据：`sh -n busybox-tests.sh` PASS；CI 全绿。

**为什么是 OS 层功能改动**

这是 tmpfs rename、文件内容读回和 exec 的行为回归。即使当前上游已有对应实现形状，测例也能防止未来回退。

## #878 teardown usercopy from kernel tasks

**问题 / 根因**

StarryOS 退出清理路径会处理 robust futex list 和 `clear_child_tid`。旧实现通过 `current().as_thread()` 推导当前线程、地址空间和 futex table；当清理发生在非用户线程上下文，或 usercopy/page fault 重入当前地址空间锁时，会把“当前 CPU 上的任务一定是用户线程”的假设带进 kernel task 路径，可能触发 `kernel task` panic、错误 futex table 查找或 page-fault/usercopy 重入。

**修复内容**

- 用户内存 region/string 检查先确认当前任务是用户线程；非线程上下文返回 `EFAULT` / `AccessDenied`。
- page fault 处理前检查当前地址空间锁是否已被持有，避免递归锁路径进入 sleep/panic。
- robust futex teardown 显式传入正在退出的 `Thread`，owner TID、`ProcessData` 和 private futex table 都从退出线程取得。
- `clear_child_tid` 唤醒绑定退出线程的 `ProcessData`。
- `AsThread::as_thread()` 增加 `#[track_caller]`，便于后续定位错误上下文。

**测试 / 状态**

- PR：[#878](https://github.com/rcore-os/tgoskits/pull/878)
- 状态：READY OPEN；2026-05-23 已执行 `gh pr ready`，本次 `gh pr view` 显示 `isDraft=false`、`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`。
- CI：CI rollup 显示 container/qemu/self-hosted 相关 job 已通过；host 侧部分 job skipped，属于 workflow 矩阵结果。
- 本地证据：`git diff --check upstream/dev...HEAD` PASS；`cargo fmt --check` PASS；现有 `test-futex-robust-list`、`test-mt-execve` 覆盖 teardown ABI。macOS 上 `cargo xtask clippy --package starry-kernel` 被既有 Mach-O/percpu baseline 问题阻断，未作为有效信号。

**为什么是 OS 层功能改动**

这是线程退出、futex、usercopy、page fault 和地址空间锁之间的上下文边界修复。M6 guest cargo 只是高压 workload，真正修的是内核在 teardown 路径上如何选择正确的进程/线程上下文。

## #879 RawMutex competitive wakeup

**问题 / 根因**

SMP 下 `RawMutex::unlock` 旧逻辑用 `notify_one_with` 把 `owner_id` 直接切到等待者。被唤醒任务还没有真正从 `lock()` 返回、也没有拿到 guard 时，owner 状态已经指向它；如果该任务重新进入同一把锁，会被误判为“已经拥有 mutex”，触发 self-owner panic。后续诊断还说明 mutex guard 不能跨任务转移，否则 owner-id 语义会被破坏。

**修复内容**

- `RawMutex::unlock` 先用 `Release` 把 `owner_id` 清零，再唤醒一个等待者。
- 等待者醒来后仍走 CAS acquire 路径，真正抢到锁后才成为 owner。
- guard marker 改为 `GuardNoSend`，防止 mutex guard 跨任务/线程移动。
- 新增 `qemu-smp4/test-rawmutex-handoff`，4 个 worker 并发执行 `mmap`、fault、`mprotect`、`munmap`，压测地址空间锁竞争。

**测试 / 状态**

- PR：[#879](https://github.com/rcore-os/tgoskits/pull/879)
- 状态：READY OPEN；2026-05-23 已执行 `gh pr ready`，本次 `gh pr view` 显示 `isDraft=false`、`mergeStateStatus=CLEAN`，`mergeable=MERGEABLE`。
- CI：CI rollup 显示 container/qemu/self-hosted 相关 job 已通过；host 侧部分 job skipped，属于 workflow 矩阵结果。
- 本地证据：`git diff --check upstream/dev...HEAD` PASS；`cargo fmt --check` PASS；新增 `test-suit/starryos/normal/qemu-smp4/test-rawmutex-handoff`。macOS 上 `cargo xtask clippy --package ax-sync` 被既有 Mach-O/percpu baseline 问题阻断。

**为什么是 OS 层功能改动**

这是 SMP sleepable mutex 的所有权和 wakeup 顺序语义修复。它影响地址空间锁、page cache、进程退出和 futex wait/wake 等内核共享路径，不能用降低 cargo 并行度或改脚本替代。

## #885 file syscall thread snapshot

**问题 / 根因**

`openat`、`mkdirat`、`mknodat` 这类文件创建 syscall 先读取用户态 pathname，然后再通过 `current().as_thread()` 获取 `umask` / credential。M6 多核 cargo 压力中曾在 `fd_ops.rs:269` 看到 `kernel task` panic，说明二次读取 current 的路径在 SMP/preempt/用户内存访问压力下不够稳。

注意：该现象来自 RISC-V QEMU MTTCG，MTTCG 本身有 LR/SC 原子语义风险，所以不能把它单独说成真实硬件上的确定性 OS bug。PR 口径是更保守的 OS hardening：文件创建语义应使用 syscall 入口调用者的线程上下文。

**修复内容**

- `sys_openat` 入口保存当前 `Thread`，后续 `umask` 和 `cred` 都从同一个 thread 读取。
- `sys_mkdirat` / `sys_mknodat` 同步保存入口 thread，后续 mode/permission 的 umask 计算不再二次读取 current。
- 新增 `qemu-smp4/test-openat-umask-smp`，多个 worker 并发执行 `umask + openat(O_CREAT)`，覆盖共享 fs/files 和 SMP 调度压力。

**测试 / 状态**

- PR：[#885](https://github.com/rcore-os/tgoskits/pull/885)
- 状态：DRAFT OPEN，等待 GitHub Actions。
- 本地证据：`git diff --check` PASS；`cargo fmt --all --check` PASS；`cargo check -p starry-kernel --target riscv64gc-unknown-none-elf` PASS；`zig cc -target riscv64-linux-musl` C 语法 PASS；`cargo xtask starry test qemu --arch riscv64 -g normal -c test-openat-umask-smp --list` PASS。
- 本地限制：macOS 缺 `debugfs`，Docker qemu 尝试时 Docker CLI 无输出卡住，因此完整 qemu case 交给 CI。

**为什么是 OS 层功能改动**

这是 syscall 入口上下文和文件创建 ABI 的稳定性修复，不是 M6 脚本规避。即使最终 8 核 M6 仍需要真实硬件或正确模拟器验证，这个补丁也能让文件创建路径对 SMP 调度更稳。

## 仍缺 / 待确认

- #693 已按 review 恢复所有 `CLONE_VFORK` 父进程阻塞；关键 riscv64/x86_64/aarch64 Starry QEMU 已过，剩 loongarch `apk-curl` 网络 timeout 需要 rerun，以及 reviewer 状态。
- #694 虽已归档合入，但本次 `gh` 查询偶发 GraphQL EOF；如汇报需要完整 CI 明细，建议重新查 Actions run。
- #695 已合入且历史记录为 CI 绿，但仍缺一个更小、独立的 rsext4 inode allocation regression 描述。
- #842/#843/#844/#878/#879 当前都已经 ready review，元数据为 CLEAN / MERGEABLE；下一步等待维护者 review/用户批准。
- #800 冲突已清，从 DIRTY 变为 BLOCKED；CI 正在跑，剩旧 review 状态，不纳入当前 M6 展示主线。
- #885 是新的 draft OS hardening PR，来自多核 cargo 压力信号；需要等 Actions，再决定是否 ready。
