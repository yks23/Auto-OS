# BigLab-B 答辩 PPT 规划：杨凯森

更新时间：2026-05-29

## 叙事主线

一句话主线：

> 用 AI 驱动的持续迭代框架改进 StarryOS，完成从 OS bug mining、PR 合入，到 StarryOS guest 内自举编译 StarryOS，再到多核性能瓶颈分析的闭环。

不要按时间流水讲。按“目标 -> 方法 -> PR -> 自举 -> 性能 -> 反思”讲。

## 建议 19 页结构

### 1. 标题页

标题：AI 驱动 StarryOS 自举编译与内核改进
副标题：BigLab-B 总结 / 杨凯森 / `yks23`

口播：

> 我的工作不是单个 syscall，而是一条完整工程线：建立 AI 迭代框架，持续发现和修复 StarryOS 的 OS 问题，最终支撑 StarryOS 在 guest 内编译 StarryOS，并分析多核性能瓶颈。

### 2. 总览：我完成了什么

放四个数字卡，再在页脚放 host 对齐参考作为下界参照：

- `12` 个已合入 PR：`#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926`
- `331s`：8 核 AArch64/HVF guest 内完整 self-build 最快结果
- `951s -> 331s`：guest 端到端调优收益 `2.87x`
- `20/11/5/3s`：1000 次 fork/exec/wait，8 路 `6.67x`

host 对齐参考小注：

```text
Host aligned reference: 29s
同一 StarryOS 源码、同一 AArch64/SMP8 kernel 配置、同一 no-LTO/opt0/cgu256 profile；
只把 cargo/rustc 从 StarryOS guest 移到 macOS host；
j1=85s，j8=29s，host 对齐参考编译并行加速比 2.93x；不用于计算 guest speedup。
```

### 3. BigLab-B Task 1：tg-arceos-tutorial 基础练习

讲清楚这不是 Harness，而是 BigLab-B 第一项规定任务：

- fork `rcore-os/tg-arceos-tutorial/tree/test` 到自己的仓库；
- 在 `test` 分支完成 5 个基础 `exercise-*`；
- 本地对应完成项：`exercise-printcolor`、`exercise-hashmap`、`exercise-altalloc`、`exercise-ramfs-rename`、`exercise-sysmap`；
- 这部分训练 ArceOS 小实验、no_std Rust、allocator、RAMFS/VFS、系统符号/地址映射和 QEMU 运行。

### 4. BigLab-B Task 2 阶段 1：Harness / AI 迭代框架

画流程：

```text
daily sync dev -> choose OS target -> reproduce -> shorten loop
  -> fix kernel -> add test-suit -> local validation -> PR -> CI -> tracking
```

强调：

- 每日同步 `origin/dev`，PR 也基于 `dev`，避免越做越偏；
- 超过 2h 就缩短反馈链路；
- 找到 OS bug 就转 PR；
- 没有 root cause 就加日志；
- harness 覆盖 QEMU/HVF guest build、rootfs 检查、短基准、日志解析、PR tracking；
- focus 在 infra 基建和 verifiable 进展：每个结论要能被日志、PASS marker、test-suit 或 CI 支撑。

口播：

> 这套框架属于 Task 2 的第一阶段。它的作用是把“跑一个很久的大实验”拆成一组可复现、可 review、可合入的 OS 行为改进。

### 5. PR 总览：按 OS 层分组

不要按编号堆列表。按层分组：

| 类别 | PR |
| --- | --- |
| Linux ABI / syscall | `#692 #693 #694 #843 #878 #885` |
| 文件系统 / VFS / 设备 | `#695 #800 #844` |
| SMP / 同步 / 调度 | `#842 #879 #926` |

注：页面角落标注“截至 2026-05-29：表内 12 个核心 PR 均已合入 `dev`”。本地复现材料和性能日志只作为实验过程证据，不放入已合入 PR 主表。

### 6. 重点 PR 1：vfork 不是小细节

讲 `#693`。

四段：

- 问题：`CLONE_VFORK` 要求父进程等到子进程 `exec/exit`，旧路径在部分 child stack 情况下没有保持这个同步。
- 根因：实现把“是否阻塞父进程”的判断和 child stack 形态绑定，破坏了 Linux ABI。
- 修复：只要带 `CLONE_VFORK`，就建立 `vfork_done` 并等待 child `exec/exit`，不让父进程提前继续。
- 测例：`test-vfork` 覆盖 Linux ABI 语义，避免回归。

联系 BusyBox：

> 影响范围不是一个脚本，而是 BusyBox `sh/timeout`、`posix_spawn` 类路径和 Cargo 子进程模型。它们都依赖父子进程顺序正确，否则会出现同步死锁、状态错乱或脚本异常。

### 6. 重点 PR 2：futex / teardown 的失败路径

讲 `#692` + `#878`。

- `#692 robust futex cleanup faults`：线程退出时 robust-list 坏指针、pending futex 不能拖垮退出路径；修复点是容错清理坏 entry，并把 pending 单独处理。
- `#878 teardown usercopy/futex context`：进程退出和 futex teardown 不能假设当前任务一定还是普通用户线程；修复点是让退出清理路径对上下文更保守。
- 测例：`test-futex-robust-list` 按 Linux ABI 拆 pending cleanup 和 bad-head tolerance。

口播重点：

> 这类 PR 的价值在失败路径：真实 workload 下线程退出、错误指针、pending futex 很常见，内核不能因为用户态给了坏链表就把退出路径拖崩。

### 7. 重点 PR 3：文件系统 / 设备语义

讲 `#695 #800 #844`。

- `#695 rsext4 inode bitmap`：ext4 block group 的 inode bitmap 未初始化时，allocator 不能直接跳过可用 inode；修复后初始化 uninit bitmap 并继续分配。
- `#800 direct device full transfer`：直接设备读写要完整传输，避免 `/dev/zero`、镜像读写或用户态 buffer 检查遇到短读/短写。
- `#844 tmpfs rename exec ELF regression`：tmpfs copy -> rename -> readback -> exec 必须稳定，保护 BusyBox/tmpfs 和构建过程中的临时文件替换。

讲法：

> 这些 PR 都是从真实应用场景倒推 OS 语义，但提交时不说“修脚本”，而是说清楚 ext4 分配、设备传输、tmpfs rename/exec 的内核行为。

### 8. 重点 PR 4：SMP / usercopy / 调度前进性

讲 `#842 #879 #885 #926`。

- `#842 SMP CPU topology`：让 `/proc`、`sysfs`、`sysconf`、affinity 暴露正确 CPU 数，用户态才会合理设置 jobs。
- `#879 RawMutex competitive wakeup`：release-before-wake，避免 owner handoff 竞争。
- `#885 file syscall thread snapshot`：syscall entry 固定用户线程上下文，后续 usercopy 不重新猜 current task。
- `#926 axtask SMP wakeup progress`：remote wakeup 时 kick 远端 CPU，补 wait queue re-enqueue 防护，解决 Cargo 尾部不前进。

口播重点：

> 这组 PR 直接服务多核 self-build：CPU topology 让用户态敢并行，RawMutex 和 axtask 保证并行任务能前进，usercopy snapshot 保护多核文件 syscall 的上下文正确。

### 9. 实验4：StarryOS 自举编译 StarryOS

画路线图：

```text
RISC-V TCG M6
  -> 长反馈，SMP TCG correctness 风险
  -> 切到 AArch64/HVF
  -> 8 核 StarryOS userland
  -> guest 内 cargo build starryos PASS
```

解释：

- RISC-V TCG 用于 correctness/milestone；
- AArch64/HVF 用于快速多核性能反馈。

### 10. 关键数字：速度演进与 host 对齐参考

放阶梯图：

```text
29s host aligned reference
  同一源码、同一 AArch64/SMP8 kernel 配置、同一 target/profile；
  只把 cargo/rustc 从 StarryOS guest 移到 macOS host。

951s baseline
  -> 642s tmp source/target
  -> 515s no LTO
  -> 427s opt0 + cgu256
  -> 379s axtask wakeup
  -> 341s optional ddebug
  -> 331s tuned best
```

旁边放：

```text
端到端真正收益：951 / 331 = 2.87x
guest 编译并行：422 / 341 = 1.24x
host 对齐编译参考：85 / 29 = 2.93x（同构建任务，cargo/rustc 在 host）
链接/串行尾段：642 / 427 = 1.50x
```

备注：`331s` 是 tuned local best，不是默认保证；链接项是 LTO/codegen/link 尾段收益，不是单独 link-only benchmark。

### 11. 各种 setting 下的速度对照

放表，核心是 setting 要讲清楚：

| setting | 说明 | 结果 |
| --- | --- | --- |
| host aligned reference j8 | 同一 StarryOS 源码、同一 AArch64/SMP8 kernel 配置、同一 target/profile，只把 cargo/rustc 从 guest 移到 host；`CARGO_BUILD_JOBS=8 RAYON_NUM_THREADS=8` | `29s` |
| host aligned reference j1 | 同上，只改 host cargo/rustc 并行度为 `CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1` | `85s` |
| guest slow baseline | AArch64/HVF StarryOS guest，`jobs=1`，release optimized，target 在 guest ext4 | `951s` |
| guest tmp source/target | `SMP=8 JOBS=8`，source/vendor/target 到 guest `/tmp`，release optimized | `642s` |
| no LTO | 上一项 + `CARGO_PROFILE_RELEASE_LTO=false` | `515s` |
| opt0+cgu256 | 上一项 + `opt-level=0`、`codegen-units=256` | `427s` |
| wakeup/runqueue fix | 上一项 + axtask wake-local/remote-kick 路线 | `379s` |
| optional ddebug tuned best | 上一项 + dynamic-debug gating，同快反馈 profile 本地最好运行 | `331s` |

说明：

- 编译部分：Cargo crate graph 用 `-j8` 并行调度，`codegen-units=256` 增加 crate 内 codegen 可拆分空间；长链路仍由 build-std、顶层 bin、ax-hal、link/codegen 和 OS 等待/FS/SMP 开销共同决定。
- 链接部分：链接本身仍接近串行，主要通过关闭 LTO、降低 opt-level、减少动态 debug/显示等非必要 feature 来减少后段 codegen/link 工作量。可汇报的尾段收益是 `642 -> 515 -> 427s`，合计 `1.50x`；没有单独 link-only benchmark。
- host 对齐参考只说明同一 StarryOS kernel 构建任务在 host 侧的并行参考，不参与 `951/331` 的 guest 端 speedup 计算；和 guest `422s -> 341s` 的差距用于说明 guest OS/FS/SMP/QEMU 成本。

### 12. 为什么完整 build 还不是 4x

公式页：

```text
T_build(N) = T_std/cache
           + T_serial(link/LTO/build.rs)
           + T_parallel_crates / N
           + T_fs(N)
           + T_smp(N)
           + T_wait(N)
```

证据：

- `jobs=12 = 609s`，负优化；
- 线程/调优 sweep 的 `331/338/349s` 结果说明继续增加内部并行没有形成稳定收益；
- 24 个 build-script wave：`27/22/27/32/32s`，小任务过并行会变慢；
- fork/exec/wait 1000 次能 `6.67x`，说明多核本身有效。

加一页或在讲稿里补“测试细项模拟”表：

| 模拟 Cargo 细项 | 微基准 | 数字 | 说明 |
| --- | --- | --- | --- |
| 反复 spawn rustc/build.rs | fork/exec/wait 1000 次 | `20/11/5/3s` | 进程链路可扩展到 `6.67x`，但这是内核热路径。 |
| 短 build-script wave | 24 个 direct rustc | `27/22/27/32/32s` | 2 路最快，过并行被 OS/FS/SMP 成本吃掉。 |
| target 小文件 metadata | rsext4 fileio | `47.5s -> 14.5s` | 每次 `sync_to_disk()` 会把并发写入串行化。 |
| Cargo 并行参考 | host aligned reference | `85s -> 29s = 2.93x` | 同源码、同 AArch64/SMP8 kernel 配置、同 target/profile 在宿主侧能吃到并行；guest 侧加速比低，说明 OS/FS/SMP/QEMU 成本明显。 |
| 纯 CPU-bound | RISC-V raw MTTCG | `3.17x` | QEMU 可给 CPU-bound 加速，但 RISC-V MTTCG 不作 correctness 证明。 |
| final link | timestamp/json 诊断 | artifact tail 约 `2s` | 331s 版本主瓶颈不是纯链接。 |

### 13. 最后一页强化：对齐对比与成因归属

建议最后加两张收束页：

```text
host aligned: 85s -> 29s = 2.93x
guest jobs-only: 422s -> 341s = 1.24x
guest tuned: 951s -> 331s = 2.87x
fork/exec/wait: 20/11/5/3s = 6.67x
```

讲法：

- host aligned reference 说明同一 StarryOS kernel 构建任务在 host 侧有并行空间；
- guest jobs-only 才是真实 StarryOS 承载 cargo 的结果；
- 差距来自 guest syscall、VFS/FS metadata、scheduler/runqueue、锁竞争、QEMU/HVF 边界和 Cargo 串行尾段；
- 所以工作不是“只调参数”，而是把每一类成本拆出微基准并形成 OS PR。

### 14. 文件系统性能候选：rsext4 deferred-sync

放短基准：

```text
before j1/j2/j4/j8: 21.5 / 21.2 / 43.5 / 47.5s
after  j1/j2/j4/j8:  5.6 /  5.0 / 11.4 / 14.5s
```

讲法：

> 普通 mutation 每次 `sync_to_disk()` 会把并行小文件写入串行化。这个候选证明 FS 短链路收益明显，但 full build `511s` 不是新最快，所以 PR 口径应该是文件系统性能/语义，而不是“4x full build”。

### 14. Demo 与复现

放：

- 本地 StarryOS macOS/HVF self-build 复现材料；
- PASS marker：

```text
===STARRYOS-BUILD-PASS jobs=8 elapsed=<seconds>===
```

命令概念：

```bash
CASE_NAME=smp8-j8-selfbuild \
KERNEL=target/aarch64-unknown-none-softfloat/release/starryos.bin \
SMP=8 JOBS=8 PROFILE=release SOURCE_TMPFS=1 \
CARGO_PROFILE_RELEASE_OPT_LEVEL=0 \
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256 \
FAST_ALLOC_SLAB_ONLY=1 \
FAST_SELFBUILD_NO_DYNAMIC_DEBUG=1 \
bash 过程记录/最终材料/scripts/run-hvf-starryos-guest-build.sh
```

现场建议：

- 不现场跑完整 331s；
- 展示 logs、RESULTS、PASS marker；
- 可现场跑短基准或 rootfs check。

### 19. 课程思考：AI 时代的 OS 实验设计

最后一页讲三点：

1. Agent 处理完整上下文的能力已经很强，但它需要清晰目标、仓库、分支、运行模式和交付标准。课程应训练学生把庞大 OS 项目拆成可验证的小任务。
2. AI 降低了工程门槛，OS 课可以更多向大一同学开放，让他们更早通过真实项目获得工程成长。
3. 选修课背景下，可以区分必修基础和进阶模块；AI 方向同学可以用自己的 AI 能力参与大型 OS 项目，但仍要围绕内存、进程、FS、syscall、并发和性能这些核心问题。

口播：

> AI 不替代 OS 理解；它让课程更适合训练“拆解复杂系统、组织证据、完成真实工程交付”的能力。

## 可能被问的问题

### Q1：为什么 RISC-V 多核不用 MTTCG？

答：RISC-V TCG 下 MTTCG 对 LR/SC reservation 的跨 hart 失效建模不可靠，可能破坏用户态 atomic CAS。为了 correctness，RISC-V SMP TCG 用 `-accel tcg,thread=single`，但它很慢。所以多核性能验证切到 AArch64/HVF。

### Q2：为什么 8 核 full build 没到 4x？

答：Cargo full build 不是纯并行任务。瓶颈包括 build-std、proc-macro/build.rs、link/codegen 串行段、FS metadata、wait/pipe/process 和 SMP 调度成本。短基准证明进程链路可到 `6.67x`，说明问题不在“多核完全无效”，而在 full cargo 的混合瓶颈。

### Q3：BusyBox 相关成果怎么讲？

答：BusyBox 是真实 Linux 小应用入口。我的成果不是完整 BusyBox 支持，而是从 BusyBox/sh/tmpfs/device/topology 等场景反推出 OS 语义修复，例如 `#693`、`#844`、`#800`、`#842`。

### Q4：哪些 PR 最能体现 OS 理解？

答：`#693` 体现 clone/vfork 进程 ABI；`#879/#926` 体现 SMP 锁和调度唤醒；`#885` 体现 syscall entry/usercopy 上下文；`#695/#800/#844` 体现文件系统和设备语义。

### Q5：哪些内容不放入已合入 PR 成果主表？

答：主表只放已经合入 `dev` 的 12 个 OS PR。StarryOS 自举编译、多核测速、HVF 复现实验属于本地实验和 demo 证据，单独讲“如何复现”和“性能瓶颈”，不包装成已合入 PR。
