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
| M6 v20 `SMP=4`, `jobs=2`, subset | 几分钟 | `===M6-SELFBUILD-SUBSET-PASS===` |
| M6 v21 `SMP=4`, `jobs=2`, full early pressure | 到 `syn v2.0.117` | 无 panic/SIGSEGV，但 heartbeat 后续消失，触发 stall |
| M6 v22 `SMP=4`, `jobs=2`, `starry-kernel/smp` | 到 `syn v1.0.109` 后 StoreFault | 早期 kernel-lib 阶段已覆盖 SMP feature，并暴露具体内核 fault |

结论：

- 小 workload 已有速度收益。
- M6 full 还没有宣称最终 pass；当前成果是把 OS 层问题边界定位清楚了。
- jobs=2 真实压力暴露了后续要拆的调度、响应性和内存/页表类问题。

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

要讲的话：

- 最新口径是：v20 的 `SMP=4 + jobs=2` subset 已 PASS；v21 full early 进入真实 cargo build，到 `syn v2.0.117` 后 heartbeat 消失；v22 已让早期 `starry-kernel` lib 阶段启用 `smp` feature，并进一步暴露 StoreFault。
- 所以当前展示不声称完整多核 M6 已 PASS，而是说明多核已经从“能启动”推进到“能复现实打实的 OS 调度压力”。

## 13. 内核改进与当前证据

页面内容：

| 内核点 | 已做改进 | 证据 |
| --- | --- | --- |
| 用户态抢占 | timer interrupt 返回后显式 yield | v19 中 guest heartbeat 持续输出，并已越过 v18 的 `thiserror` 卡点；v21 进一步暴露 jobs=2 heartbeat stall |
| 用户任务迁移 | 用户态运行 pin CPU，blocked wake 保持用户任务亲和性 | v17 的 cross-CPU wake panic 不再复现 |
| run queue | 记录 run queue load，kernel task 可按负载分配 | 为后续 jobs=2/4 提供基础 |
| 诊断能力 | `track_caller` 记录 preempt/block callsite | 后续 panic 能更快定位内核调用点 |
| SMP feature wiring | `starry-kernel` 新增 `smp = ["ax-feat/smp"]` | v22 早期 lib 阶段已打印 `--features smp`，随后暴露 StoreFault |

要讲的话：

- 这一页讲“OS 实现进步了什么”，不是讲 Docker 或脚本。
- 当前结论是：SMP kernel 的调度和用户任务亲和性已经比之前更稳，`jobs=2` subset 已经通过；完整 cargo jobs 还要继续分阶段放大并补 regression。

## 14. 下一步计划

页面内容：

- 基于 v22 的 `StoreFault` 抽一个更小的 OS regression，避免继续用完整 selfbuild 才得到反馈。
- 补三个 OS regression：
  - CPU-bound 用户进程不能饿死 heartbeat/其他可运行任务。
  - blocked 用户任务唤醒不能错误迁移到没有 StarryOS thread context 的 CPU。
  - `starry-kernel/smp` 早期 lib 阶段必须覆盖 `ax-task/smp` 路径。
- 再逐步放大到 `jobs=4`，观察 futex、锁、文件系统路径。
- `thread=multi` 只作为速度实验；correctness 仍以 `thread=single` 或真硬件为准。

要讲的话：

- 现在的主线是内核正确性：先把 SMP 下用户态 workload 跑稳，再追求多线程速度。
- 脚本和 rootfs 只是保证验证可复现，不作为 PR 的主体。

## 15. 结尾页

页面内容：

一句话总结：

> 单核 guest self-build 已跑通；多核线已经看到小 workload 加速，jobs=2 subset 通过，并把真实 M6 压力暴露的问题收敛到内核调度、迁移和响应性上。

要讲的话：

- 对老师汇报时，核心句子是：这些不是脚本修补，而是 SMP 下内核调度、迁移和同步语义的修正。
- 之后所有 PR 也按 OS 功能和 regression 测例组织。
