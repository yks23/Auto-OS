# 展示 PPT 大纲

## 1. 标题页

标题：

> StarryOS Self-build / Showtime: 单核已跑通，多核继续加速

副标题：

> 把 binary、日志、checksum、问题链路和 PR 计划整理成可复现材料

要讲的话：

- 这次展示的核心不是单个 patch，而是 StarryOS guest self-build 这条链路已经留下完整证据。
- 单核线已经能证明 guest 内编译出 StarryOS kernel；多核线继续验证加速和正确性。

## 2. 为什么拆成单核和多核

页面内容：

- 单 CPU：建立稳定 baseline。
- 多 CPU：验证 guest cargo build 是否真实并行提速。
- PR：把过程中暴露的问题拆成可 review 的小修复。

要讲的话：

- 多核变量很多：kernel、QEMU、rootfs、cargo workload 都会互相影响。
- 所以单核先证明“能编译、能复现、证据完整”，多核再谈速度。

## 3. `showtime/` 目录结构

页面内容：

```text
showtime/
├── single-cpu/
├── multi-cpu/
├── shared/
└── presentation/
```

要讲的话：

- `single-cpu/` 放本次已跑通的 guest-built binary、日志、runbook、bugfix 和 PR 线索。
- `multi-cpu/` 放 SMP 实验、benchmark、风险记录、QEMU 风险说明。
- `shared/` 放 rootfs、环境、命令模板和大文件索引。
- `presentation/` 是这次展示的讲述材料。

## 4. 单核 M6 guest self-build 已 PASS

页面内容：

- target: `riscv64-qemu-virt`
- mode: `-smp 1 -accel tcg,thread=single`
- final guest cargo build time: `132m 59s`
- success marker: `===M6-SELFBUILD-PASS===`

要讲的话：

- 这是 StarryOS guest 内部跑 Rust/Cargo workload，编译出了 StarryOS kernel。
- 这一步证明的是 guest self-build 能力，不是多核性能。

## 5. 已落盘产物和证据

页面内容：

```text
showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.elf
showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
showtime/single-cpu/binaries/riscv64-qemu-virt/SHA256SUMS
showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
```

要讲的话：

- `.elf/.bin` 是从 guest rootfs 里的最终 build output 提出来的。
- 完整 QEMU serial log 已经复制到 `showtime/`，可以复查关键成功行。
- 大 rootfs 和 `target.tar` 没有塞进展示目录，而是在 `shared/references/environment.md` 里索引。

## 6. 严谨性：同环境 A/B 验证

页面内容：

控制变量：

- 只替换 `-kernel`，其余条件不动。
- 同一个 Linux QEMU 容器。
- 同一个 fsck 后 rootfs。
- `-smp 1, tcg,thread=single`。
- snapshot 模式，不污染镜像。

判据：

- 进入 StarryOS userland。
- 找到 rootfs 内已完成的 StarryOS ELF。
- 打印 `===M6-SELFBUILD-PASS===`。
- 无 `panic/trap/FATAL/error`。

| 对象 | kernel | 结果 |
| --- | --- | --- |
| reference | `.guest-runs/riscv64-m6/starry-up1.bin` | PASS |
| guest-built | `showtime/.../starryos-singlecpu.bin` | PASS |

要讲的话：

- 这一页体现严谨性：不是只跑 guest-built kernel，而是和原本正确编译的 reference kernel 做同环境对照。
- 可以说“只换 kernel，其余条件不动，两边同一个 smoke 都过”，这比单独展示一个 PASS 更有说服力。

## 7. PR 与 bugfix 线索

页面内容：

| PR | 问题 | 修复内容 | 测例 / CI |
| --- | --- | --- | --- |
| #692 robust futex cleanup | robust-list 坏指针或 pending futex 不能拖垮线程退出 | 容错清理坏 entry，pending 单独处理；测例按 Linux ABI 拆成 pending cleanup 和 bad-head tolerance | `test-futex-robust-list`；新 CI 已触发 |
| #693 vfork child-stack clone | `CLONE_VM|CLONE_VFORK` 带私有 child stack 时不应按传统 vfork 阻塞父进程 | 只在 `CLONE_VFORK && stack == 0` 时等待，避免 posix_spawn 类同步死锁 | `test-vfork`；旧 CI 有取消，需要重跑 |
| #694 IPv4-mapped IPv6 socket | AF_INET6 socket 使用 IPv4-mapped address 时要走 IPv4 backend 且保持 IPv6 用户态语义 | bind/connect 归一化到 IPv4，getsockname/getpeername/accept 包装回 IPv4-mapped IPv6 | `bug-af-inet6-v4mapped`；x86_64 已过，其他架构旧失败需看日志/重跑 |
| #695 rsext4 inode bitmap | uninit inode bitmap 的 block group 不能被 allocator 直接跳过 | 识别并初始化 uninit inode bitmap，再从该 group 分配 inode | inode allocation regression；CI 绿 |
| new checkpoint tar readback | 大 checkpoint tar 读回出现 duplicate extent | 先抽最小 FS regression，再决定 PR | 待最小复现 |

要讲的话：

- 这些 PR 都和 StarryOS 跑复杂 workload 的稳定性有关，但要按“问题、修复、测例、CI 状态”拆开讲。
- #692 是刚处理过的重点：旧测例要求“坏链表头后仍必须处理 pending”比 Linux 行为更强，已经拆成 pending cleanup 和 bad-head tolerance 两个 case。
- 每个 PR 都要能对应到测例，方便助教 review 和复现。

## 8. 多核目标：先正确，再加速

页面内容：

- 第一层：小 workload 证明多核方向有速度收益。
- 第二层：`SMP=4 + thread=single` 验证 StarryOS SMP 内核正确性。
- 第三层：逐步打开 `jobs=2/4`，观察线程、futex、调度、文件系统压力。
- 速度实验：`thread=multi` 只能作为速度潜力，不作为 correctness 证明。

要讲的话：

- 多核不能只展示“启动了 4 个 CPU”，要展示 OS 是否真的能调度复杂用户态 workload。
- Rust/Cargo build 很适合做压力源，因为它同时打到进程、线程、锁、文件系统和内存管理。

## 9. 多核已经拿到的证据

页面内容：

| 配置 | 时间 | 结果 |
| --- | --- | --- |
| hello-world `-smp 1`, `-j1` | 约 176s | pass |
| hello-world `-smp 4`, `-j4` | 约 62s | 约 2.8x speedup |
| raw CPU `-smp 4`, `thread=single` | 4/8 workers: 0.90s / 1.01s | correctness baseline pass |
| raw CPU `-smp 4`, `thread=multi` | 4/8 workers: 0.33s / 0.32s | 约 2.76x / 3.17x speedup |
| 8 核启动 `-smp 8 -m 4G` | 约 5s 到 userland | `smp = 8`，`TEST PASSED` |
| 8 核 `-m 6G` | 早期 boot | bitmap allocator `CAP=1048576 pages`，需要 `1572864 pages` |
| M6 v20 `SMP=4`, `jobs=2`, subset | 几分钟 | `===M6-SELFBUILD-SUBSET-PASS===` |
| M6 v21 `SMP=4`, `jobs=2`, full early pressure | 到 `syn v2.0.117` | 无 panic/SIGSEGV，但 heartbeat 后续消失，触发 stall |
| M6 v22 `SMP=4`, `jobs=2`, `starry-kernel/smp` | 到 `syn v1.0.109` 后 StoreFault | 早期 kernel-lib 阶段已覆盖 SMP feature，并暴露具体内核 fault |
| M6 v27 `SMP=4`, `jobs=2`, mutex caller | 到 `quote v1.0.45` | 定位 `RawMutex` 自重入 caller: `task/user.rs:38` |
| M6 v28 `SMP=4`, `jobs=2`, unlock-then-wake | 已越过 `quote`，进入 `syn v2.0.117` | 修正 owner handoff 后继续推进，仍在验证 |
| M6 `-smp 8`, MTTCG, `jobs=4`, tmpfs target | 进入 `starry-kernel-lib` | `compiler_builtins` build script `Exec format error`，转为 tmpfs regression |
| M6 `-smp 8`, MTTCG, `jobs=4`, ext4 target | 已越过 tmpfs 早期失败点 | 当前主线，继续验证完整 cargo selfbuild |

结论：

- 小 workload 已有速度收益。
- raw syscall CPU benchmark 已排除 libc/cargo 变量，证明 MTTCG 有真实并行收益，但当前最好约 3.17x，还没有稳定达到 4x。
- 8 核启动已经验证；6G 失败是 allocator 容量上限，不是 secondary HART bring-up 失败。
- M6 full 还没有宣称最终 pass；当前成果是把 OS 层问题边界定位到 futex、allocator、tmpfs rename/readback/exec 这些内核路径。

## 10. 多核暴露的内核实现问题

页面内容：

- 用户态 timer interrupt:
  - 现象：guest cargo 长 CPU 段中 host 仍活跃，但 guest heartbeat 可能长时间不推进。
  - 原因：`uctx.run()` 因 timer interrupt 返回后，只回到用户循环，没有显式把这个点交给调度器。
  - 修正：`ReturnReason::Interrupt` 分支显式 `yield_now()`，让 CPU-bound 用户进程不能长期占住 run queue。
- 用户任务跨 CPU 唤醒:
  - 现象：放开 blocked task 跨 CPU 负载均衡后，用户态 syscall 路径里 `current().as_thread()` 可能看到 kernel task 并 panic。
  - 原因：StarryOS 的用户线程上下文和 `TaskExt` 还不是完全 migration-safe。
  - 修正：用户态运行期间 pin 到当前 CPU；带 `TaskExt` 的用户任务从 blocked 状态唤醒时优先回到原 CPU。
- run queue 负载:
  - 增加每 CPU run queue load 统计。
  - 非 pinned 的 kernel task 可以按负载分配，用户任务先保持亲和性。
- mutex handoff:
  - 现象：v27 在 `quote` 阶段报 `Thread(76) tried to acquire mutex it already owns at task/user.rs:38`。
  - 原因假设：unlock 时直接把 owner 写给 waiter，SMP 竞争下会出现 owner 指向等待者但等待者还没真正持锁的中间状态。
  - 修正：unlock 先清 `owner_id`，再 `notify_one`，让 waiter 重新 CAS 抢锁。
- futex wait:
  - 现象：8 核 cargo smoke 里 `FUTEX_WAIT` 在 wait queue 锁内读用户 futex word，触发 `prepare_user_memory will lock aspace in atomic context`。
  - 原因：锁内 recheck 用普通 `vm_read()`，可能 fault/populate 用户页并拿 aspace mutex。
  - 修正：锁前做普通用户读；锁内只用窄的 `vm_read_u32_noprepare()` 读已存在的 32-bit futex word。
- allocator:
  - 现象：`-smp 8 -m 6G` 早期 panic，bitmap 需要 `1572864` 页但 CAP 只有 `1048576` 页。
  - 临时路线：展示和 M6 8 核实验先用 `-m 4G`；真正修复应让 allocator metadata 随平台内存动态扩展或配置化。

要讲的话：

- 多核不是只改启动参数；真正暴露的是内核调度语义。
- 当前策略是先保证用户态长时间 workload 在 SMP kernel 下稳定推进，再逐步放开更激进的跨 CPU 并发。

## 11. QEMU RISC-V TCG 风险

页面内容：

```sh
-accel tcg,thread=single  # correctness baseline
-accel tcg,thread=multi   # speed experiment
```

要讲的话：

- `thread=multi` 可以观察速度潜力，但 RISC-V LR/SC reservation 正确性有风险。
- 最终 correctness 要么用 `thread=single`，要么用真硬件/更可信模拟器。

## 12. SMP selfbuild 怎么测

页面内容：

| 阶段 | 配置 | 目的 |
| --- | --- | --- |
| baseline | `SMP=1`, `jobs=1`, `rayon=1` | 完整 selfbuild 串行墙钟时间 |
| SMP 内核正确性 | `SMP=4`, `thread=single`, `jobs=1` | 先证明多 hart kernel 能长时间支撑真实 guest selfbuild |
| 用户态并发压力 | `SMP=4`, `thread=single`, `jobs=2/4` | 在正确性基线上逐步放大 futex/锁/调度压力 |
| 速度实验 | `SMP=4/8`, `thread=multi`, `jobs=4/8` | 观察宿主 TCG 并行速度信号，单独标风险 |
| 8 核 boot smoke | `SMP=8`, `m=4G` | 先验证 HART bring-up、userland、短 workload |
| 8 核 full M6 tmpfs | `SMP=8`, `m=4G`, `jobs=4`, tmpfs target | 已定位为 tmpfs rename/readback/exec 候选问题，不作为 PASS 口径 |
| 8 核 full M6 ext4 | `SMP=8`, `m=4G`, `jobs=4`, ext4 target | 当前主线，继续验证完整 cargo selfbuild |

要讲的话：

- 最新口径是：8 核启动已 PASS，raw CPU MTTCG 有 2.76x/3.17x 速度信号；tmpfs full M6 暴露 `build-script` 的 `Exec format error`，ext4 full M6 已越过这个早期点并继续推进。
- 所以当前展示不声称完整多核 M6 已 PASS，而是说明多核已经从“能启动”推进到“能复现实打实的 OS 调度压力”。

## 13. 内核改进与当前证据

页面内容：

| 内核点 | 已做改进 | 证据 |
| --- | --- | --- |
| 用户态抢占 | timer interrupt 返回后显式 yield | v19 中 guest heartbeat 持续输出，并已越过 v18 的 `thiserror` 卡点；v21 进一步暴露 jobs=2 heartbeat stall |
| 用户任务迁移 | 用户态运行 pin CPU，blocked wake 保持用户任务亲和性 | v17 的 cross-CPU wake panic 不再复现 |
| run queue | 记录 run queue load，kernel task 可按负载分配 | 为后续 jobs=2/4 提供基础 |
| mutex handoff | unlock 先清 owner 再 wake waiter | v28 已越过 v27 的 `quote` mutex panic |
| futex wait | 锁前普通读，锁内 `vm_read_u32_noprepare` 窄读 | 避免 wait queue no-IRQ 区间内触发 aspace prepare |
| allocator capacity | 8 核 6G 暴露 bitmap CAP 只覆盖 4G 页 | `-m 4G` boot smoke 通过；6G 是明确 allocator 修复点 |
| 诊断能力 | `track_caller` 记录 preempt/block callsite | 后续 panic 能更快定位内核调用点 |
| SMP feature wiring | `starry-kernel` 新增 `smp = ["ax-feat/smp"]` | v22 早期 lib 阶段已打印 `--features smp`，随后暴露 StoreFault |
| signal/wait 用户缓冲 | `rt_sigaction`、signal frame、`wait4` 不再在锁/async poll 内访问用户内存 | raw benchmark 能稳定执行 `clone + wait4`，后续可拆 PR |
| ioctl 用户缓冲 | TTY/pipe ioctl 曾在持锁路径 `vm_read/vm_write`，启动 shell 会打印 atomic usercopy 警告 | 先复制内核状态，锁外访问用户缓冲；新增 `test-ioctl-usercopy-locks`，轻量 QEMU 验证 `TEST PASSED` 且警告消失 |

要讲的话：

- 这一页讲“OS 实现进步了什么”，不是讲 Docker 或脚本。
- 当前结论是：SMP kernel 的调度和用户任务亲和性已经比之前更稳，`jobs=2` subset 已经通过；完整 cargo jobs 还要继续分阶段放大并补 regression。

## 14. 下一步计划

页面内容：

- 保留 v28 的 mutex handoff 证据，但下一步优先处理 8 核 futex/exec 两个新阻塞点。
- 把 raw CPU MTTCG benchmark 固化为短反馈环；当前 `thread=multi` 最好约 3.17x，未到 4x。
- 把 futex wait 的 locked recheck 修复成正式 PR：窄 `noprepare` 用户读 + `bug-futex-wait-wake` regression。
- 把 `-smp 8 -m 6G` bitmap CAP panic 抽成 allocator regression；展示路线继续用 4G。
- 把 tmpfs `build-script` 的 `Exec format error` 抽成最小 regression：写 ELF 到 tmpfs、rename、读 final ELF magic、再 `fork + execve`。
- 保持 ext4 作为今晚完整 cargo selfbuild 主线，不让 tmpfs 问题继续阻塞长跑。
- 基于 mutex handoff 和 futex wait 抽更小的 OS regression，避免继续用完整 selfbuild 才得到反馈。
- 补这些 OS regression：
  - CPU-bound 用户进程不能饿死 heartbeat/其他可运行任务。
  - blocked 用户任务唤醒不能错误迁移到没有 StarryOS thread context 的 CPU。
  - `starry-kernel/smp` 早期 lib 阶段必须覆盖 `ax-task/smp` 路径。
  - `ioctl` 等 syscall 不能在 atomic/preempt-disabled 路径访问用户缓冲。
  - `futex wait` 锁内不能 fault/populate 用户页。
- 再逐步放大到 `jobs=4`，观察 futex、锁、文件系统路径。
- `thread=multi` 只作为速度实验；correctness 仍以 `thread=single` 或真硬件为准。

要讲的话：

- 现在的主线是内核正确性：先把 SMP 下用户态 workload 跑稳，再追求多线程速度。
- 脚本和 rootfs 只是保证验证可复现，不作为 PR 的主体。

## 15. 结尾页

页面内容：

一句话总结：

> 单核 guest self-build 已跑通；多核线已经看到小 workload 加速，jobs=2 subset 通过，并把真实 M6 压力暴露的问题收敛到内核调度、迁移和响应性上。

> 2026-05-21 最新口径：8 核启动已验证，raw CPU MTTCG 有真实速度信号；tmpfs 路线暴露 build-script exec/readback 问题，ext4 路线正在继续完整多核 M6，不声明最终 pass。

要讲的话：

- 对老师汇报时，核心句子是：这些不是脚本修补，而是 SMP 下内核调度、迁移和同步语义的修正。
- 之后所有 PR 也按 OS 功能和 regression 测例组织。
