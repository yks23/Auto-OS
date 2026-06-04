# BigLab-B 总结报告：AI 驱动 StarryOS 自举编译与内核改进

> 杨凯森 / GitHub: `yks23`
> 代码与材料仓库：<https://github.com/yks23/Auto-OS>
> TGOSKit fork：<https://github.com/yks23/tgoskits>
> 上游目标仓库：<https://github.com/rcore-os/tgoskits/tree/dev>
> 更新时间：2026-05-29

## 一、整体概述

本次 BigLab-B 的主线不是单点实现某个 syscall，而是围绕一个真实目标持续推进：

```text
AI 驱动的持续迭代框架
  -> 发现 StarryOS 在真实 Linux/Rust workload 下的 OS 问题
  -> 拆成可 review 的 TGOSKit PR
  -> 支撑 StarryOS 在 guest 内编译 StarryOS
  -> 进一步验证多核/HVF 场景下的性能与瓶颈
```

最终成果可以分成四类：

1. 建立了用于 StarryOS / TGOSKit 的 AI 辅助开发流程，包括同步上游 `dev`、长任务监控、反馈链路缩短、PR tracking、测试证据归档和按 OS 功能拆 PR。
2. 向 TGOSKit `dev` 提交并合入了一组 StarryOS / ArceOS 内核行为 PR，覆盖 futex/vfork/socket/rsext4/device/tmpfs/SMP/usercopy/axtask 等方向。
3. 跑通了 StarryOS guest 内完整编译 StarryOS 的自举路径，并把路线从 RISC-V TCG 长反馈迁移到 Apple Silicon 上的 AArch64/HVF 快反馈。
4. 对多核编译 StarryOS 的性能瓶颈做了量化分析：最快 8 核 guest full build 为 `331s`，相对最慢 guest baseline `951s` 的端到端调优收益为 `2.87x`；严格同 profile 只改 guest jobs 的比例为 `422s -> 341s = 1.24x`；LTO/codegen/link 串行尾段通过 profile 调整从 `642s` 收敛到 `427s`，收益 `1.50x`；同时用短基准证明 OS 的进程并行链路可以达到 `6.67x`。

答辩首页建议直接放四个数字卡：

| 数字 | 含义 |
| --- | --- |
| `12` 个已合入 PR | `#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926`，都已进入 `rcore-os/tgoskits:dev`。 |
| `331s` | 8 核 AArch64/HVF StarryOS guest 内完整 self-build 的本地最快结果。 |
| `951s -> 331s` | guest 内端到端从最慢 baseline 到最快调优结果，`2.87x`；这是调优收益，不是严格 jobs-only 加速比。 |
| `20/11/5/3s` | 1000 次 `fork/exec/wait` 在 `jobs=1/2/4/8` 下的短基准，8 路为 `6.67x`。 |

同时放一个 host 对齐参考：`29s`，条件是同一份 StarryOS 源码、同一 AArch64/SMP8 kernel 配置、同一 no-LTO/opt0/cgu256、slab/no-dynamic-debug profile，只把 cargo/rustc 从 StarryOS guest 移到 macOS host；不经过 guest filesystem、syscall、scheduler 和 QEMU guest userland。同口径把 host Cargo 并行度降为 `CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1` 时为 `85s`，所以 host 对齐参考的编译并行加速比是 `85s / 29s = 2.93x`。它用于说明同一构建任务本身有并行空间；和 guest 内 `422s -> 341s` 的差距，正是 guest OS/FS/SMP/QEMU 成本需要解释的部分。

答辩时把加速比分三类讲，不混用分母：

| 口径 | 对比 | 加速比 | 解释 |
| --- | --- | --- | --- |
| 端到端真正收益 | guest slow baseline `951s` -> tuned best `331s` | `2.87x` | 真实 StarryOS guest 内 full self-build，从最慢可复现基线到当前最好结果。 |
| 编译并行收益 | 同一 optional-ddebug profile 下 guest `jobs=1 422s` -> `jobs=8 341s` | `1.24x` | 严格只看 guest 内 Cargo jobs 并行；host 对齐参考为 `85s -> 29s = 2.93x`，表示同一 StarryOS kernel 构建任务在 host 侧可并行，但不进入 guest。 |
| 链接/串行尾段收益 | guest 默认 8 核 release `642s` -> no LTO `515s` -> opt0+cgu256 `427s` | `1.50x` | 这是 LTO/codegen/link 后段工作量缩短，不是独立 link-only benchmark；日志没有单独拆出纯链接器耗时。 |

本报告重点讲 BigLab-B。BigLab-A/基础训练部分在本次工作中主要作为背景能力；BigLab-B Task 1 是 `tg-arceos-tutorial/test` 分支上的 5 个基础 `exercise-*`，Task 2 才进入 Harness、StarryOS PR、自举编译和多核性能分析。

## 二、BigLab-B Task 1：tg-arceos-tutorial 基础练习

Task 1 的内容是 fork <https://github.com/rcore-os/tg-arceos-tutorial/tree/test>，在自己的仓库中完成规定的 5 个基础 `exercise-*` 练习。我的对应仓库是 <https://github.com/yks23/tg-arceos-tutorial>，本地完成项包括：

| exercise | 训练内容 |
| --- | --- |
| `exercise-printcolor` | 基础输出、控制台路径和 QEMU 运行调试。 |
| `exercise-hashmap` | 集合结构、hash map 和 no_std Rust 工程组织。 |
| `exercise-altalloc` | 替代 allocator、内存分配路径和模块替换。 |
| `exercise-ramfs-rename` | RAMFS/VFS rename 语义，和后续 StarryOS 文件系统问题直接相关。 |
| `exercise-sysmap` | 系统符号、地址映射和异常定位基础。 |

这部分是进入 TGOSKit/StarryOS 真实内核改进前的基础训练，不应和后面的 Harness 混在一起讲。

## 三、BigLab-B Task 2 阶段 1：AI 驱动 Harness 与内核改进闭环

Task 2 阶段 1 的目标是让 AI 不只是一次性写补丁，而是在 OS 工程里形成可持续运行的闭环。实际工作中形成了下面这套规则：

```text
同步 dev 基线
  -> 选择一个 OS 行为问题
  -> 建立 Linux/StarryOS 差分或真实 workload 失败证据
  -> 缩短反馈链路并提取最小 reproducer
  -> 修内核代码
  -> 加 test-suit 或 focused regression
  -> 本地验证
  -> 推 PR / 等 CI / 写 PR tracking
```

几个关键工程约束：

- PR 目标分支使用 `rcore-os/tgoskits:dev`，不是 `main`。
- 每天或开始工作前同步 `origin/dev`，并让本地开发分支尽量贴近 `dev`，避免 PR 因长期漂移产生冲突。
- 发现 OS-level bug 后，优先拆成“问题、根因、修复、测例、风险”完整的 PR，而不是只写 showtime 脚本或 Docker workaround。
- 如果反馈链路超过 2 小时，先缩短链路：降低日志、提取短测例、复用 rootfs/cache、切到 host QEMU/HVF、先跑小 crate 或 synthetic benchmark。
- 对长任务加高信号日志：阶段 marker、crate 进度、QEMU 存活、PASS/FAIL marker、panic/trap PC、syscall 计数。
- PR 文档和本地 tracking 保留状态、CI、测试证据和下一步，避免每天被上游 `dev` 漂移拖垮。
- harness 主要覆盖三类：QEMU/HVF guest build、rootfs/镜像一致性检查、短基准和日志解析。目标不是“多跑脚本”，而是把每个进展做成 verifiable：能被 PASS marker、test-suit、CI 或日志证据复核。

这个框架在后续实验中的价值很明显：StarryOS 自举编译不是一次跑出来的，而是靠持续缩短反馈链路、抽出 OS bug、修复再验证，逐步从“能看到 Rust/Cargo workload”推进到“8 核 guest 内 full build PASS”。

## 四、BigLab-B Task 2：syscall / Linux ABI 兼容性与 OS 行为 PR

这一部分的核心不是堆 syscall 数量，而是把真实 workload 暴露出的 Linux ABI 差异变成可合入的 OS 修复。

### 3.1 已合入 PR 总表

截至 2026-05-29，通过 GitHub API 复核，下列 PR 已合入 `rcore-os/tgoskits:dev`：

| PR | 主题 | OS 层意义 |
| --- | --- | --- |
| [#692](https://github.com/rcore-os/tgoskits/pull/692) | robust futex cleanup faults | 线程退出时 robust-list 坏指针和 pending futex 不能拖垮退出路径。 |
| [#693](https://github.com/rcore-os/tgoskits/pull/693) | preserve vfork parent blocking | 恢复 Linux-compatible `CLONE_VFORK` 父进程阻塞语义。 |
| [#694](https://github.com/rcore-os/tgoskits/pull/694) | IPv4-mapped IPv6 socket | AF_INET6 socket 使用 `::ffff:a.b.c.d` 时保持 IPv6 用户态语义并走 IPv4 backend。 |
| [#695](https://github.com/rcore-os/tgoskits/pull/695) | rsext4 inode bitmap | ext4 未初始化 inode bitmap 不能导致 allocator 跳过可用 inode。 |
| [#800](https://github.com/rcore-os/tgoskits/pull/800) | direct device full transfer | 直接设备读写要完整传输，避免短读/短写破坏用户态预期。 |
| [#842](https://github.com/rcore-os/tgoskits/pull/842) | SMP CPU topology | `/proc`、`sysfs`、`sysconf`、affinity 暴露正确 CPU 拓扑，支撑并行 workload。 |
| [#843](https://github.com/rcore-os/tgoskits/pull/843) | conservative RISC-V hwprobe | Rust/Cargo RISC-V 用户态反复调用 `riscv_hwprobe` 时不再产生 ENOSYS 噪音。 |
| [#844](https://github.com/rcore-os/tgoskits/pull/844) | tmpfs rename exec ELF regression | 固化 tmpfs copy -> rename -> ELF readback -> exec 行为。 |
| [#878](https://github.com/rcore-os/tgoskits/pull/878) | teardown usercopy/futex context | 退出清理路径不能假设当前任务一定是用户线程。 |
| [#879](https://github.com/rcore-os/tgoskits/pull/879) | RawMutex competitive wakeup | 修复 SMP RawMutex handoff / guard 释放顺序风险。 |
| [#885](https://github.com/rcore-os/tgoskits/pull/885) | file syscall thread snapshot | 文件 syscall 入口固定用户线程上下文，避免后续 usercopy 读错 current task。 |
| [#926](https://github.com/rcore-os/tgoskits/pull/926) | axtask SMP wakeup progress | 修复 remote CPU wakeup / runqueue 前进性，支撑多核 cargo workload。 |

答辩时主表只讲已合入 `dev` 的 PR。仍在 review 或待合并的分支可以作为后续工作，不计入“已完成 PR 成果”。

### 3.2 重点 PR：`#693` vfork 父进程阻塞语义

**问题。** `CLONE_VFORK` 要求父进程等待子进程 `exec` 或退出。之前曾把阻塞条件错误收窄到 `stack == 0`，导致带 private child stack 的 `CLONE_VFORK` 子进程不再阻塞父进程。

**为什么重要。** 这不是一个只影响测试的小差异。BusyBox `sh`、`timeout`、`posix_spawn` 类路径依赖父子进程同步顺序。父进程过早继续运行，会造成用户栈/地址空间/文件状态观察顺序错乱，真实 workload 中会表现为脚本异常甚至段错误。

**修复。** 对所有 `CLONE_VFORK` 都设置并等待 `vfork_done`，不再用 `stack == 0` 作为是否等待的条件。

**测试。** `test-vfork` 按 Linux ABI 调整预期：即使 child stack 非零，`CLONE_VFORK` 父进程也必须等到子进程 `exec/exit`。

这个 PR 的经验是：clone/vfork 不是“进程创建的小细节”，而是 shell、busybox、cargo、rustc 子进程模型依赖的核心进程 ABI。

### 3.3 重点 PR：`#879` RawMutex 竞争唤醒

**问题。** SMP 下 RawMutex 解锁和唤醒 waiter 的顺序如果处理不好，可能出现 owner handoff 竞争、guard 跨任务释放、或者唤醒后仍观察到旧 owner 的问题。

**修复。** 调整 RawMutex 释放与唤醒顺序，保证释放 owner 状态后再唤醒 waiter，避免 waiter 在不一致状态下运行。

**测试。** 新增 `test-suit/starryos/normal/qemu-smp4/test-rawmutex-handoff`，直接覆盖 SMP4 下的竞争交接路径。

这个 PR 和后面的自举编译关系很强：Rust/Cargo workload 会制造大量短任务、文件锁、pipe/wait、mutex 竞争，SMP 锁语义不稳会在长时间编译中被放大。

### 3.4 重点 PR：`#885` file syscall thread context snapshot

**问题。** 文件创建 syscall 入口在用户线程上下文中，但旧实现后续路径可能再次通过 `current().as_thread()` 推导当前用户线程。多核压力下，当前任务上下文可能已经不是原来的用户线程，导致 usercopy 或文件创建路径读错 thread context。

**修复。** 在 syscall 入口快照用户线程上下文，后续文件创建和用户态参数处理使用这个固定上下文。

**测试。** `test-openat-umask-smp` 覆盖 SMP 下并发文件创建和 umask 语义；本地还用 synthetic cargo leaf build 验证该修复能承受更接近 Cargo 的并发压力。

这个 PR 的经验是：用户态参数进入内核后，不能在阻塞/调度/跨任务路径中反复“现场获取 current thread”。真实 OS 代码需要把 syscall entry context 当成稳定资源传下去。

### 3.5 重点 PR：`#926` axtask SMP wakeup progress

**问题。** 8 核 StarryOS guest cargo build 的尾部曾出现 cargo 父进程 sleeping、没有 rustc/build-script 子进程、整体不前进的问题。短链路排除了基础 wait/pipe/eventfd/file-lock 后，问题收敛到 SMP wakeup/runqueue 前进性。

**修复。** PR 主要包括：

- 为 blocking/wakeup 路径选择更合适的 runqueue；
- remote task wakeup 时 kick 远端 CPU；
- 补 wait queue re-enqueue 防护，避免 stale waiter 重复入队。

**测试。** 新增 `task/wait_queue_remote_wake`，并用 cargo fingerprint wave、完整 StarryOS build 作为压力证据。该 PR 已合入 `dev`。

这个 PR 是从“自举编译大 workload 卡住”反推到“调度/唤醒前进性”的典型案例，最能体现实验不是只写脚本，而是在真实压力下改内核。

### 3.6 其它已合入 PR 的讲法

答辩时不用把所有 PR 都讲成同等篇幅，但每个 PR 都要能按“问题、根因/修复、测例/影响”三段回答。

| PR | 问题与影响 | 修复与验证 |
| --- | --- | --- |
| `#692` robust futex cleanup | 线程退出时 robust-list 坏指针或 pending futex 不能拖垮退出路径。真实多线程程序退出时很容易走到这类失败路径。 | 容错清理坏 entry，pending futex 单独处理；`test-futex-robust-list` 拆 pending cleanup 和 bad-head tolerance。 |
| `#694` IPv4-mapped IPv6 socket | AF_INET6 socket 使用 `::ffff:127.0.0.1` 时，用户态仍按 IPv6 语义观察地址，但内核后端需要走 IPv4。 | bind/connect 做 v4-mapped 归一化，getsockname/getpeername/accept 再包装回 IPv6；测例为 `bug-af-inet6-v4mapped`。 |
| `#695` rsext4 inode bitmap | ext4 block group 标记 inode bitmap 未初始化时，allocator 不能直接跳过整个 group，否则明明有容量却分配失败。 | 识别并初始化 uninit inode bitmap 后继续分配 inode；加入 inode allocation regression。 |
| `#800` direct device full transfer | `/dev/zero` 等 direct device 的 read/write 不能短传输后假装成功，否则用户态 buffer、镜像读写、应用探测都会错。 | 让 direct device 尽量完成用户请求长度；用设备读写场景验证。 |
| `#842` SMP CPU topology | 多核 guest 里用户态需要通过 `/proc`、`sysfs`、`sysconf`、affinity 看到正确 CPU 数，否则 Cargo/jobs/nproc 都会误判并行度。 | 修正 CPU topology 暴露；对并行 workload 和自举编译是基础设施。 |
| `#843` conservative RISC-V hwprobe | Rust/Cargo 在 RISC-V 用户态会反复探测 `riscv_hwprobe`；持续 ENOSYS 会污染日志和反馈。 | 做保守返回，减少无意义失败噪音，不虚报硬件能力。 |
| `#844` tmpfs rename exec ELF | tmpfs 中 copy -> rename -> readback -> exec 是构建和脚本常见路径；rename 后 ELF 内容和可执行语义必须稳定。 | 加 tmpfs rename + ELF readback + exec 回归，影响 BusyBox/tmpfs 和构建临时文件替换。 |
| `#878` teardown usercopy/futex | 退出清理路径不能假设当前任务仍是普通用户线程，否则 futex/usercopy teardown 可能在错误上下文中访问。 | 让 teardown 对当前上下文更保守，配合 futex 退出路径验证。 |

## 五、BigLab-B Task 2：应用影响范围

BusyBox 这一类小应用在本实验中不是答辩 PPT 的单独一页，但它是非常重要的真实 workload。它的价值在于：一个 applet 往往组合触发多个 OS 接口，而不是只测一个 syscall。

本实验中与应用场景相关的成果可以这样归纳：

| 应用/场景 | 暴露的问题 | 对应成果 |
| --- | --- | --- |
| BusyBox `sh` / `timeout` / `posix_spawn` 类路径 | `CLONE_VFORK` 父子同步语义错误会破坏脚本执行顺序 | `#693` |
| BusyBox tmpfs copy/rename/exec | tmpfs rename 后 ELF readback/exec 行为需要稳定 | `#844` |
| `/dev/zero`、直接设备读写 | 设备文件读写不能只传输一部分就返回成功 | `#800` |
| `nproc`、cargo jobs、SMP 感知 | 用户态需要通过 `/proc`/`sysfs`/affinity 看到正确 CPU topology | `#842` |
| Alpine `apk` + `curl` | 网络、文件系统、进程、包管理组合压力；CI 中 LoongArch `apk-curl` 也暴露网络/镜像波动 | 作为压力和风险场景，不包装成已修 OS PR |

这里的结论是：应用级失败只是入口，最终 PR 必须回到内核语义。比如 `#693` 不是“修 BusyBox 脚本”，而是修 Linux `CLONE_VFORK` ABI；`#844` 不是“让某个 copy 脚本过”，而是给 tmpfs rename + ELF exec 加回归保护。

## 六、BigLab-B Task 2：StarryOS 自举编译 StarryOS

实验 4 是本次 BigLab-B 的主菜。目标是让 StarryOS 支撑一个真实大型 Rust/Cargo workload：在 StarryOS guest 内执行 `cargo build`，编译出 StarryOS。

### 5.1 路线一：RISC-V TCG self-build

最初路线是 RISC-V QEMU TCG。它的优点是和 TGOSKit 常规 RISC-V 目标一致，但缺点是反馈链路很长：

- Mac host 不是 RISC-V，必须用 QEMU TCG 动态翻译；
- RISC-V SMP 下 QEMU MTTCG 对 LR/SC reservation 的建模存在 correctness 风险；
- 因此 RISC-V SMP TCG 需要用 `-accel tcg,thread=single` 保正确性，速度很慢；
- 长时间 full build 中如果没有足够日志，很难判断是 cargo 正常前进、QEMU 慢、还是 OS 卡死。

这一路线的主要结论是：RISC-V M6 可以作为 correctness/milestone 方向，但不是快速优化多核性能的主反馈链路。

### 5.2 路线二：AArch64/HVF 快反馈

为了缩短反馈链路，后续切到 Apple Silicon macOS 上的 AArch64/HVF：

- host CPU 和 guest ISA 都是 AArch64；
- QEMU 使用 HVF 硬件虚拟化，而不是跨 ISA TCG；
- 8 核 StarryOS 可以在分钟级进入 userland 并运行 Rust/Cargo workload；
- 这让多核调度、文件系统、进程/wait、Cargo critical path 的问题可以快速暴露。

这一路线上暴露并修复了 AArch64/HVF SMP 启动相关问题，包括 GICv3、secondary CPU 初始化顺序、GICR MMIO window 等。本次答辩中把它作为本地实验底座和技术过程说明，不计入已合入 PR 成果。

### 5.3 完整 self-build 结果

最终已经完成 8 核 StarryOS guest 内完整 `cargo build -j8` 编译 StarryOS。关键数字：

```text
guest slow baseline: 951s
guest best completed: 331s
host-side aligned reference: 29s
```

详细 setting 对照：

| setting | 编译环境与条件 | 结果 | 说明 |
| --- | --- | --- | --- |
| host aligned reference j8 | 同一 StarryOS 源码、同一 AArch64/SMP8 kernel 配置、同一 release profile：`cargo build -p starryos --bin starryos --target aarch64-unknown-none-softfloat -Z build-std=core,alloc,compiler_builtins --features qemu,gic-v3,cntv-timer,smp --release`；AArch64/SMP8 axconfig，no-LTO/opt0/cgu256，slab/no-dynamic-debug；`CARGO_BUILD_JOBS=8 RAYON_NUM_THREADS=8`；cargo/rustc 运行在 macOS host。 | `29s` | 和 guest 编译同一 kernel；只去掉 guest FS、syscall、scheduler、QEMU guest userland 成本，用作 host 侧对齐参考。 |
| host aligned reference j1 | 同上，只把 host cargo/rustc 并行度改成 `CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1`。 | `85s` | host 对齐参考编译并行加速比 `85s / 29s = 2.93x`。 |
| guest slow baseline | AArch64/HVF StarryOS guest，`jobs=1`，release optimized，target 在 guest ext4，Cargo 自举 `core/alloc/compiler_builtins`，共约 293 个编译单元。 | `951s` | 最慢 guest baseline。 |
| guest tmp source/target | AArch64/HVF StarryOS guest，`SMP=8 JOBS=8`，source/vendor/target 放入 guest `/tmp`，release optimized。 | `642s` | 先减少 ext4 source/target I/O 干扰。 |
| no LTO | 上一项 + `CARGO_PROFILE_RELEASE_LTO=false`。 | `515s` | 减少链接/LTO 串行尾部。 |
| opt0+cgu256 | 上一项 + `CARGO_PROFILE_RELEASE_OPT_LEVEL=0`、`CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256`。 | `427s` | 降低 codegen 成本，并增加 crate 内 codegen 可拆分空间。 |
| wakeup/runqueue fix | 上一项 + axtask wake-local/remote-kick 路线。 | `379s` | 修掉多核 Cargo 尾部不前进问题后的完整 build。 |
| optional ddebug tuned best | 上一项 + dynamic-debug gating，并使用同一快反馈 profile 的本地最好运行。 | `331s` | 当前最快本地结果；不作为严格 jobs-only 加速比分母。 |

速度演进：

```text
951s  slow guest baseline
  -> 642s  source/target 放入 tmp 路径后的默认 release
  -> 515s  关闭 LTO
  -> 450s  opt-level=0
  -> 427s  codegen-units=256
  -> 379s  axtask wakeup/runqueue 修复后
  -> 357s  no-dynamic-debug + explicit IPI
  -> 341s  ddebug optional
  -> 331s  tuned local best
```

可报告的三类比例：

```text
端到端真正收益：951s / 331s = 2.87x
guest 编译并行：422s / 341s = 1.24x   # 严格同 profile 只改 jobs
host 对齐编译参考：85s / 29s = 2.93x   # 同一构建任务，只把 cargo/rustc 放在 host
链接/串行尾段：642s / 427s = 1.50x
  关闭 LTO：642s / 515s = 1.25x
  opt0+cgu256：515s / 427s = 1.21x
```

这里要特别注意：`331s` 是调优 profile 的本地最好结果，不应说成默认命令在任意机器上稳定保证，也不应叫严格 jobs-only 加速比；`29s/85s` 是 host 对齐参考，和 guest 编译同一 StarryOS AArch64/SMP8 kernel，但 cargo/rustc 运行在 host，不经过 guest 的 syscall/FS/scheduler/QEMU userland 成本；链接项目前没有独立 link-only 计时，只能表述为 LTO/codegen/link 串行尾段缩短。

从编译/链接角度看，这些 setting 的作用可以这样解释：

- 编译部分主要靠 Cargo crate graph 的 `-j8` 并行调度；`codegen-units=256` 给单个 crate 的 codegen 更多拆分空间；剩余长链路由 build-std、顶层 bin、ax-hal、link/codegen 和 OS 等待/FS/SMP 开销共同决定。
- 链接部分和 build graph 尾部仍接近串行，所以主要通过关闭 LTO、降低 opt-level、减少 dynamic-debug/display 等非关键 feature 来缩短后段 codegen/link 时间。
- `jobs=12` 和 `rustc -Z threads=4` 都变慢，说明 8 核 guest 里继续盲目增加并行度会被 wait/FS/SMP 锁竞争和调度成本反吃。

### 5.4 为什么没有达到 4x

完整 Cargo build 不是纯并行任务。更准确的模型是：

```text
T_build(N) = T_std/cache
           + T_serial(link/LTO/build.rs)
           + T_parallel_crates / N
           + T_fs(N)
           + T_smp(N)
           + T_wait(N)
```

实验中收集到的证据：

| 证据 | 结论 |
| --- | --- |
| `fork+exec+wait` 1000 次：`20/11/5/3s` | OS 进程创建/等待短链路在 8 路能达到 `6.67x`，多核不是完全无效。 |
| rustc build-script wave 24 个任务：`27/22/27/32/32s` | 小任务甜点在 2 路，超过后被 wait/FS/SMP 开销反吃。 |
| `jobs=12` 完整 build 为 `609s` | 8 vCPU 上继续加 Cargo jobs 是负优化。 |
| `331/338/349s sweep` | 线程/调优 sweep 的本地结果显示继续增加内部并行未形成稳定收益。 |
| `cargo check = 574s` | full check 不能替代 full build 做短反馈。 |
| `BUILD_STD=none = 426s` | 预注入 sysroot 有价值，但跳过 build-std 不是主提速点。 |

更细地说，full Cargo build 里每一类怀疑点都对应一个小模拟：

| Cargo 行为 | 对应微基准/模拟 | 已有数字 | 归因 |
| --- | --- | --- | --- |
| 反复启动 `rustc`、`build.rs`，父进程 `waitpid` 回收 | 1000 次 `fork+exec+wait` wave，`jobs=1/2/4/8` | `20/11/5/3s`，8 路 `6.67x` | 证明 StarryOS 进程链路能并行；但这仍是内核进程、wait queue、调度器热路径。 |
| 很多很短的 build-script/rustc 子任务 | 24 个 direct rustc build-script wave，`jobs=1/2/4/6/8` | `27/22/27/32/32s` | 小任务在 2 路最快，超过后被 fork/exec、wait、FS 写入和 SMP 锁成本反吃。 |
| Cargo 大量小文件 create/write/rename/unlink | rsext4 fileio 短基准，模拟 target metadata 更新 | before `21.5/21.2/43.5/47.5s`，after `5.6/5.0/11.4/14.5s` | 文件系统普通 mutation 每次 `sync_to_disk()` 会串行化小文件并发；这是明确 OS FS 问题。 |
| target/source/vendor 反复读写 | 把 source/vendor/target 搬到 guest `/tmp` | 默认 cold `951s/917s` 级别，tmp 路线到 `642s` | 说明虚拟块设备 + guest FS metadata 是大头之一；`/tmp` 降低块设备落盘压力。 |
| 只增加 cargo jobs | `jobs=12` 完整 build | `609s`，慢于 `jobs=8` 的 `331/341s` | 8 vCPU 上过量并发导致调度、锁、FS 和缓存争用增加。 |
| Cargo 图可并行性参考 | host 对齐参考构建，`jobs=1/8` | `85s -> 29s = 2.93x` | 同源码、同 kernel 配置、同 target/profile 在宿主侧能体现并行空间；guest 同 profile 只有 `422s -> 341s = 1.24x`，差距来自 guest OS/FS/SMP/QEMU 边界和 cargo 短任务成本。 |
| 纯 CPU-bound 多 worker | RISC-V raw CPU MTTCG syscall benchmark | `workers=8` 下 single/multi TCG `1010162us -> 318373us = 3.17x` | QEMU 多线程执行模型能给 CPU-bound workload 加速；但 RISC-V MTTCG 有 LR/SC correctness 风险，不能作为最终正确性证据。 |
| 最终链接和 artifact 汇合 | timestamp/json cargo 诊断 | final executable artifact tail 约 `2s`，`starry-kernel` 后段约 `17-20s` | 纯 linker 不是 331s 版本主瓶颈；慢的是 build-std、Cargo critical path、codegen 和 OS 开销。 |

后续更可能有效的 OS 方向不是继续调 cargo 参数，而是：

- 文件系统 metadata/sync 策略；
- wait/pipe/process 短任务开销；
- runqueue load balance / idle pull；
- SMP 锁竞争；
- 更细的 profiling 和 `/proc/stat` 可观测性。

### 5.5 文件系统性能候选：rsext4 deferred-sync

最新本地发现：rsext4 普通 write/create/link/unlink/rename 路径每次都 `sync_to_disk()`，在小文件并行 workload 下会严重串行化。

本地实验补丁把普通 mutation 改成延迟到显式 `sync/fsync/flush` 落盘，短基准结果：

```text
before jobs=1/2/4/8: 21.5 / 21.2 / 43.5 / 47.5s
after  jobs=1/2/4/8:  5.6 /  5.0 / 11.4 / 14.5s
```

`jobs=8` 从 `47.5s` 到 `14.5s`，约 `3.27x`。只替换 kernel 的完整 self-build 控制变量也 PASS，用时 `511s`。这证明 FS 短链路收益成立，但完整 cargo 仍被其他瓶颈主导，所以这个候选 PR 应按“文件系统性能/语义”来写，不包装成 full build 新最快。

## 七、可复现材料与 Demo

当前材料主要分三层：

1. **PR 与 CI 证据**
   - `success-pr/PR-TRACKING.md`
   - `过程记录/最终材料/pr-report.md`
2. **self-build 和多核报告**
   - `过程记录/最终材料/report/hvf-8core-current-status.md`
   - `过程记录/最终材料/report/compile-speed-matrix-20260523.md`
   - `过程记录/最终材料/report/presentation-number-cheatsheet.md`
3. **本地复现和展示材料**
   - `过程记录/最终材料/report/hvf-8core-current-status.md`
   - `过程记录/最终材料/report/compile-speed-matrix-20260523.md`
   - `过程记录/最终材料/report/presentation-number-cheatsheet.md`

建议现场 demo 分两档：

- 稳定 demo：展示本地复现命令、PASS marker、结果表和已有 logs，不现场跑完整 331s build。
- 可选 demo：现场运行短基准，例如 `fork+exec+wait` wave 或 rootfs 检查，证明环境和 StarryOS userland 可进入。

## 八、对 OS 内核理解的总结

这次实验让我对几个 OS 层问题有了更实在的理解：

1. **Linux ABI 的失败路径也很重要。** robust futex、vfork、socket sockaddr、riscv_hwprobe 都说明，兼容性不只是成功返回值一致，错误路径、坏指针、flags、边界值也必须稳定。
2. **真实应用会组合触发 OS 子系统。** BusyBox、Alpine、Cargo/Rust 不会只调用一个 syscall，它们会把进程、文件系统、设备、网络、poll/wait、用户内存访问混在一起。
3. **SMP bug 很多不是立即 panic，而是前进性问题。** cargo build 尾部 sleeping、没有子进程、无 panic，是典型调度/wakeup 问题，需要短链路和高信号日志收敛。
4. **性能优化必须分解。** 不能只看 `-j8` 是否快，要拆 `T_fs(N)`、`T_smp(N)`、`T_wait(N)`、`T_serial` 和 `T_parallel/N`。
5. **AI 可以放大工程能力，但必须被测试和 review 约束。** AI 很适合读代码、生成候选修复、提取日志、写 PR body；但必须有 test-suit、CI、review 和 root cause，否则容易把 workaround 当成果。

## 九、对 OS 课程和实验设计的思考

在 AI 能力快速发展的情况下，OS 课实验可以更强调“真实系统工程闭环”。

**1. Agent 与任务拆解。** 现在的 Agent 已经能处理很长的工程上下文。只要任务目标、代码仓库、分支、运行模式、交付目标和验证方式给得足够清楚，学生在 Agent 协助下完成工程项目的门槛会明显降低。当前 Agent 的短板是：当需求本身不明确、交付目标模糊时，它无法自动替学生完成任务拆解。因此，课程可以重点训练学生如何面对一个庞大的 OS 项目，把目标一步步拆成可验证的小问题，并提供足够的信息让 AI 高效参与。

**2. 课程开放对象与培养角度。** OS 课可以更多向大一同学开放。在 AI 的帮助下，工程难度已经显著下降；低年级同学如果能较早参与真实系统项目，读代码、跑测试、看日志、修 bug、提 PR，会获得非常快的成长。OS 课可以定位成一门能够带来实战能力飞跃的课程。

**3. 选修课背景下的多元化参与。** OS 课成为选修课后，可以区分“必须掌握的基础内容”和“可选进阶内容”。对于 AI 方向同学，可以鼓励他们利用自己的 AI 知识，去完成过去单凭个人力量在单门课程中几乎不可能实现的大型系统项目。同时，课程安排仍要围绕 OS 核心事务：内存、进程、文件系统、syscall、并发和性能，让学生在完成工程的同时不觉得枯燥。

总结来说，AI 不应该替代 OS 理解；它更适合让学生把时间花在任务拆解、证据组织、系统验证和真实工程交付上。

## 十、答辩时重点讲法

最稳的一句话：

> 我的 BigLab-B 主线是用 AI 驱动的持续迭代框架改进 StarryOS，最终支撑 StarryOS guest 内完整编译 StarryOS。过程中合入了一组 OS 行为 PR，覆盖 Linux ABI、文件系统、SMP 同步、usercopy 和调度唤醒；在 AArch64/HVF 8 核 guest 中，完整 self-build 最快 `331s`，相对最慢 guest baseline `951s` 的端到端调优收益为 `2.87x`；严格同 profile 只改 jobs 的比例为 `422s -> 341s = 1.24x`。同时短基准证明纯进程链路能达到 `6.67x`，说明多核是有效的，full cargo 未到 4x 的主要瓶颈已收敛到 Cargo critical path、FS、wait/pipe/process 和 SMP 调度/锁成本。

需要避免的说法：

- 只把已合入 `dev` 的 PR 放入成果主表，未合入分支放到后续工作或不主动讲。
- 不说“完整 cargo 已经 4x”。实际可报告是 `2.87x`。
- 不说“331s 是默认命令保证值”。它是本地调优 profile 的最好值。
- 不把 showtime 脚本说成 OS 修复。PR 必须按 OS 行为讲。
