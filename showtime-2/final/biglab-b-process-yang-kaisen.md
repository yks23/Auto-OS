# BigLab-B 过程纪要：杨凯森

> GitHub: `yks23`
> 材料仓库：<https://github.com/yks23/Auto-OS>
> TGOSKit fork：<https://github.com/yks23/tgoskits>
> 上游目标仓库：<https://github.com/rcore-os/tgoskits/tree/dev>
> 整理时间：2026-06-04

这份材料用于写报告里的“过程汇报”和答辩口播。它不只列结果，而是把从基础训练、AI/Harness 闭环、OS bug 拆 PR、StarryOS 自举编译、多核性能分析到复现材料沉淀的路线串起来。

## 1. 总体主线

本次 BigLab-B 的主线不是实现一个孤立功能，而是围绕一个真实目标持续迭代：

```text
让 StarryOS 支撑真实 Rust/Cargo workload
  -> 在 StarryOS guest 内编译 StarryOS
  -> 用长 workload 暴露 syscall、FS、futex、SMP、scheduler 等 OS 问题
  -> 把确认的问题拆成可 review、可 CI 验证的 TGOSKit PR
  -> 用复现脚本和性能曲线解释 correctness 与 performance 的边界
```

最终可以归纳成四类成果：

1. 完成 BigLab-A / BigLab-B Task 1 的基础训练，补齐后续 OS 调试所需的 Rust、no_std、allocator、VFS、syscall、QEMU 基础。
2. 建立 AI 辅助 OS 开发闭环：同步 `dev`、构造复现、缩短反馈、拆 OS PR、本地验证、等待 CI、更新 tracking。
3. 合入一组 StarryOS / TGOSKit 行为修复 PR，覆盖 Linux ABI、文件系统、futex、usercopy、SMP 拓扑、同步与调度唤醒。
4. 跑通 StarryOS guest 内 self-build，并用 AArch64/HVF 多核环境分析为什么 `-smp 8` 和 `cargo -j8` 不能线性加速。

## 2. 前置训练：BigLab-A 与 BigLab-B Task 1

### 2.1 BigLab-A

BigLab-A 对应 `tg-rcore-tutorial` 路线，仓库为 <https://github.com/yks23/tg-rcore-tutorial.git>。本地完成和整理过的分支包括：

| 分支/目录 | 训练重点 |
| --- | --- |
| `tg-rcore-tutorial-ch{1,2}-yks23` | 用户态程序、批处理系统、特权级切换和基础 trap/syscall 入口。 |
| `tg-rcore-tutorial-ch3-yks23` | 多道程序、任务切换、应用上下文保存恢复。 |
| `tg-rcore-tutorial-ch4-yks23` | 地址空间、页表、用户/内核地址隔离。 |
| `tg-rcore-tutorial-ch5-yks23` | 进程抽象、fork/exec/wait 语义。 |
| `tg-rcore-tutorial-ch6-yks23` | 文件系统与 VFS 基础。 |
| `tg-rcore-tutorial-ch8-yks23` | 并发、同步、死锁和线程相关机制。 |
| `tg-rcore-tutorial-ch{3,4,5}-yks23-t2l10` | 把多个章节的任务切换、地址空间、进程语义串起来做综合练习。 |

这部分的价值在后续很直接：StarryOS self-build 出问题时，很多现象都会落回 trap/syscall、地址空间、进程、VFS 或同步原语。

### 2.2 BigLab-B Task 1

BigLab-B Task 1 是 `tg-arceos-tutorial/test` 分支上的 5 个基础 exercise。对应仓库为 <https://github.com/yks23/tg-arceos-tutorial>。

| exercise | 内容 | 后续关联 |
| --- | --- | --- |
| `exercise-printcolor` | 控制台输出、基础工程结构、QEMU 运行。 | 后续日志、marker、panic 输出都依赖稳定控制台路径。 |
| `exercise-hashmap` | 集合结构和 no_std Rust 组织。 | 后续内核数据结构、fd table、wait queue 等需要类似思路。 |
| `exercise-altalloc` | allocator 替换与内存分配路径。 | self-build 压力下页分配、堆分配、内存回收都会被放大。 |
| `exercise-ramfs-rename` | RAMFS/VFS rename 语义。 | 后续 `tmpfs rename + ELF exec`、Cargo target 临时文件替换直接相关。 |
| `exercise-sysmap` | 符号映射、地址定位、异常排查。 | 后续 panic/trap PC、内核 backtrace 和 QEMU 日志定位用得到。 |

Task 1 是基本功，Task 2 才进入 Harness、StarryOS PR、自举编译和多核性能分析。

## 3. 必要背景知识

这一部分可以放在报告前面，也可以作为答辩时被问到的补充口径。

### 3.1 syscall 基本路径

用户程序不能直接访问内核资源，例如文件系统、进程表、网络栈和设备。它会通过特定指令进入内核态，把 syscall id 和参数交给内核。内核根据 syscall id 分发到对应处理函数，检查用户指针和权限，执行内核逻辑，然后把返回值写回用户态寄存器并返回。

可以简化成：

```text
用户态 libc / runtime
  -> 发起 syscall 指令，携带 syscall id 和参数
  -> CPU 进入内核态 trap/syscall entry
  -> 内核保存用户上下文，读取 syscall id
  -> syscall table 分发
  -> 访问 task / fd table / VFS / futex / socket / mm 等子系统
  -> 返回错误码或结果
  -> 恢复用户上下文，回到用户态
```

本实验里的很多 bug，本质上都发生在这条路径上：例如用户指针拷贝时 current thread 不稳定、文件 syscall 中途阻塞后上下文变化、futex cleanup 处理坏用户指针、`vfork` 父子同步语义错误。

### 3.2 fork、vfork、clone 的语义差异

`fork`、`vfork`、`clone` 都和“创建新的执行流”有关，但语义不同。

| 接口 | 语义重点 | 典型用途 | 本实验关联 |
| --- | --- | --- | --- |
| `fork` | 创建子进程，父子进程逻辑上有独立地址空间，通常通过 copy-on-write 共享物理页直到写入。 | shell 启动程序、普通进程创建。 | Cargo/build script/rustc 会产生大量子进程，fork/exec/wait 成本影响编译性能。 |
| `vfork` | 子进程和父进程临时共享地址空间，父进程必须阻塞，直到子进程 `exec` 或退出。 | `posix_spawn`、shell 快速启动程序。 | PR `#693` 修复了 `CLONE_VFORK` 父进程阻塞语义。 |
| `clone` | Linux 更底层的创建接口，通过 flags 决定共享地址空间、文件表、信号处理、线程组等资源。 | pthread、容器 runtime、特殊进程创建。 | `CLONE_THREAD`、`CLONE_VFORK`、wait/futex 语义都在真实 workload 中被触发。 |

所以 `vfork` 不是 `fork` 的简单快版本。它依赖更强的父子同步：父进程提前继续运行会破坏用户态程序假设，BusyBox、shell、`posix_spawn` 类路径都可能异常。

### 3.3 futex

`futex` 是 Linux 用户态同步的关键机制，全称可以理解为 fast userspace mutex。常规情况下，锁的竞争和释放先在用户态通过原子操作完成；只有竞争失败、需要睡眠或唤醒时才进入内核。

本实验里 futex 相关问题主要有两类：

- 线程退出时的 robust futex cleanup：如果用户态 robust-list 指针坏了，内核不能因为 cleanup 出错拖垮整个退出路径。
- wait/wakeup 前进性：多核下某个任务睡眠后，必须能被正确唤醒并进入合适 CPU 的 runqueue，否则长时间 Cargo workload 会出现“没有子进程但 cargo 也不前进”的尾部卡住。

### 3.4 VFS、tmpfs、rsext4

VFS 是 Virtual File System，即虚拟文件系统层。它把用户态看到的 `open/read/write/rename/exec` 等接口抽象成统一路径，再转发到具体文件系统实现，例如 tmpfs、ext4/rsext4、设备文件等。

本实验里 VFS/FS 的典型问题包括：

- tmpfs `copy -> rename -> exec` 后，ELF 内容和可执行语义必须稳定。
- rsext4 inode bitmap 未初始化时，不能误判没有可分配 inode。
- direct device 读写不能短传输后假装成功。
- Cargo target 目录会制造大量小文件、临时文件、rename、metadata 查询和删除，FS 共享路径会影响多核编译性能。

### 3.5 Cargo build script 和 proc-macro

Rust/Cargo 编译并不是简单地运行一批 `rustc`。很多 crate 带有 `build.rs`，Cargo 会先把 `build.rs` 编译成一个可执行程序，再运行它。这个程序可以探测系统能力、生成 Rust 代码、生成链接参数或配置环境变量。

一个简化例子：

```rust
// build.rs
fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rustc-cfg=has_custom_feature");
}
```

Cargo 的大致驱动顺序是：

```text
读取 Cargo.toml
  -> 发现 crate 有 build.rs
  -> 调用 rustc 编译 build.rs
  -> 运行生成的 build-script 可执行文件
  -> 收集 build-script 输出的 cargo: 指令
  -> 再调用 rustc 编译真正的库/二进制 crate
```

proc-macro 也会引入额外编译和执行阶段。它们往往不长，但会形成依赖门槛：下游 crate 必须等这些节点完成，`-j8` 才能继续释放更多可并行任务。这是解释“rustc 并不算短，但 Cargo 仍然不长期打满 8 核”的关键背景。

## 4. Task 2 方法论：AI/Harness 闭环

Task 2 的第一阶段不是直接追求一个最终数字，而是建立可持续排查 OS 问题的闭环：

```text
同步上游 dev
  -> 选择一个 OS 行为问题或真实 workload 失败点
  -> 构造最小复现或差分测试
  -> 缩短反馈链路
  -> 修改内核代码
  -> 加 test-suit / focused regression
  -> 本地格式化、检查、QEMU 验证
  -> 推 PR 到 dev
  -> 等 GitHub Actions
  -> 把状态写入 PR tracking
```

这个流程里有几个原则：

- PR 基线使用 `rcore-os/tgoskits:dev`，避免从旧 fork 或 `main` 直接混大范围 diff。
- OS bug 要拆成小 PR：一个 PR 只修一个行为面，例如 futex、vfork、VFS、RawMutex、axtask wakeup。
- 长任务超过 2 小时后，不再盲目重跑，而是先缩短反馈：减少日志、提取小复现、复用 rootfs/cache、切到 host QEMU/HVF、先跑 synthetic benchmark。
- 日志要高信号：phase marker、heartbeat、当前 crate、QEMU 存活、panic/trap、PASS/FAIL marker。
- showtime/demo 脚本和 OS 修复分开：复现材料可以帮助展示，但不能把脚本 workaround 当成内核成果。

这个闭环的收益是，StarryOS self-build 的失败不会只停留在“跑不通”，而是能逐步拆出可合入的内核修复。

## 5. 已合入 OS PR 线索

截至整理时，报告主表只把已合入 `rcore-os/tgoskits:dev` 的 PR 作为成果。核心 PR 如下：

| PR | 方向 | 关键问题 |
| --- | --- | --- |
| `#692` | robust futex | 线程退出时 robust-list 坏指针和 pending futex cleanup 容错。 |
| `#693` | vfork | `CLONE_VFORK` 父进程必须等子进程 `exec/exit`，不能被 `stack == 0` 错误限制。 |
| `#694` | socket ABI | IPv4-mapped IPv6 socket 地址语义。 |
| `#695` | rsext4 | 未初始化 inode bitmap 不能导致 inode 分配失败。 |
| `#800` | device I/O | direct device read/write 要尽量完整传输。 |
| `#842` | SMP topology | `/proc`、`sysfs`、`sysconf`、affinity 暴露正确 CPU 数。 |
| `#843` | RISC-V hwprobe | 对 Rust/Cargo 常见 `riscv_hwprobe` 做保守兼容，减少 ENOSYS 噪声。 |
| `#844` | tmpfs/exec | tmpfs copy、rename、ELF readback、exec 语义回归。 |
| `#878` | teardown | 用户线程退出清理路径不能假设 current 一定是普通用户线程。 |
| `#879` | RawMutex | SMP 竞争释放/唤醒顺序，避免 handoff 状态不一致。 |
| `#885` | file syscall | syscall 入口快照用户线程上下文，避免后续 usercopy 读错 current task。 |
| `#926` | axtask wakeup | remote CPU wakeup / runqueue / wait queue 前进性，支撑多核 Cargo workload。 |

这些 PR 的共同点是：它们不是为了某个 demo 特判，而是把真实 workload 触发的问题回收到 Linux ABI 或 OS 子系统语义上，再加回归测试。

## 6. 单核阶段：先跑通，再缩短反馈

### 6.1 早期路线：RISC-V TCG

最初的 self-build 路线是 Docker 里跑 Linux + Alpine + RISC-V rootfs，再用 QEMU RISC-V TCG 启动 StarryOS guest，在 guest 内编译 StarryOS。

这条路线的优点是和 TGOSKit 常规 RISC-V 目标一致；缺点是反馈非常慢：

- macOS host 不是 RISC-V，QEMU 需要动态翻译，编译密集 workload 会被翻译成本放大。
- RISC-V SMP TCG 的 LR/SC 在 MTTCG 下有 correctness 风险；为了保证多核原子语义，需要 `-accel tcg,thread=single`，速度进一步下降。
- 带大量日志时，一次 full build 可能达到约 6 小时；不打重日志时，单次也可能约 100 分钟。
- 如果没有 heartbeat、crate marker、panic/trap 位置，很难判断是正常慢、QEMU 慢，还是 OS 卡住。

所以单核阶段的重要结论不是“RISC-V 跑得最快”，而是：它适合作为 correctness/milestone 路线，但不适合作为多核性能调优的主反馈链路。

### 6.2 单核期间做过的尝试

单核阶段主要做了这些事情：

1. 稳定 rootfs 和工具链：使用 Alpine/RISC-V 用户态，处理 Rust/Cargo、musl gcc/g++、build-std 所需依赖。
2. 降低日志成本：从全量 syscall/log 转向阶段 marker、heartbeat、当前 crate 和 PASS/FAIL marker。
3. 固化正确性参数：guest cargo 使用 `CARGO_BUILD_JOBS=1`、`RAYON_NUM_THREADS=1`，先避免多核 I/O 与调度问题混进来。
4. 处理运行时兼容问题：例如 `riscv_hwprobe` 噪声、usercopy/futex teardown、tmpfs rename/exec、vfork 同步等。
5. 把确认的 OS 行为问题拆 PR，而不是只在 demo 脚本里绕过。

这部分应放在“单核期间所作尝试”页。可以这样讲：

> 单核阶段不是只等编译结束，而是在长反馈里不断找最小问题。早期在 Docker/Linux/Alpine/RISC-V 里跑，和 macOS 宿主环境差别很大；QEMU TCG 翻译慢，带日志一次可到 6 小时，不打重日志也约 100 分钟。因此我先把日志改成高信号 marker，再把 vfork、futex、tmpfs、usercopy、hwprobe 等问题拆成 OS PR。单核阶段的价值是证明 StarryOS 能承载 Rust/Cargo workload，并为多核阶段提供更干净的正确性基础。

## 7. 快反馈迁移：AArch64/HVF

为了分析多核性能，后续把主要实验路线迁移到 Apple Silicon macOS 上的 AArch64/HVF：

- host 和 guest 都是 AArch64，避免跨 ISA TCG 动态翻译。
- QEMU 使用 HVF 硬件虚拟化，反馈从小时级降到分钟级。
- 可以跑 8 核 StarryOS guest，并持续采集 QEMU 进程 CPU 利用率。
- 能更快暴露 GICv3、secondary CPU boot、SMP topology、wakeup/runqueue 等问题。

这一路线后来形成 PR `#984` 的 app/docs 复现材料：`apps/starry/macos-selfbuild` 下包含 rootfs 准备、guest self-build 脚本、QEMU AArch64/HVF 配置、README 和 RESULTS。

## 8. 多核阶段：从 900 多秒到 300 多秒

多核阶段不要只说“开了 8 核”，而要把优化口径分清楚。

### 8.1 端到端速度演进

StarryOS guest 内 full self-build 的主要演进如下：

| 阶段 | 时间 | 说明 |
| --- | ---: | --- |
| slow guest baseline | `951s` | 早期 guest baseline，单核/慢 profile，target 在 guest ext4，反馈慢。 |
| source/target 放入 tmp | `642s` | 减少 ext4 source/target I/O 干扰后的 8 核 release 路线。 |
| 关闭 LTO | `515s` | 减少 LTO/link/codegen 串行尾部。 |
| opt-level=0 + cgu256 | `427s` | 降低 codegen 成本，增加 crate 内 codegen 可拆分空间。 |
| axtask wakeup/runqueue 修复 | `379s` | 修复多核 Cargo 尾部不前进问题后，完整 build 可稳定完成。 |
| no-dynamic-debug + explicit IPI | `357s` | 降低不必要 feature/log 路径，明确远端唤醒。 |
| optional ddebug | `341s` | 同一快反馈 profile 下的 jobs=8 结果。 |
| tuned local best | `331s` | 当前本地最快完整 self-build 结果。 |

这条线可以报告为端到端调优收益：

```text
951s / 331s = 2.87x
```

注意：这是从最慢可复现 baseline 到当前最佳调优的总收益，不是严格“只把 1 核改成 8 核”的加速比。

### 8.2 严格 jobs-only 加速比

为了回答“8 核到底带来多少编译并行收益”，需要用同一 profile 只改变 Cargo jobs：

```text
guest same profile:
  jobs=1: 422s
  jobs=8: 341s
  speedup = 422 / 341 = 1.24x
```

这说明：在 StarryOS guest 内，单纯把 Cargo 并行度从 1 调到 8，只带来约 `1.24x`。这不是参数没生效，而是 workload 层和 guest OS 层共同限制了并行效率。

### 8.3 macOS 宿主对照

同一 StarryOS kernel 构建任务放到 macOS host 上，结果是：

```text
macOS host native release:
  jobs=1: 96s
  jobs=8: 42s
  speedup = 96 / 42 = 2.29x

macOS host guest-aligned profile:
  jobs=1: 85s
  jobs=8: 29s
  speedup = 85 / 29 = 2.93x
```

这两个数字的用途不同：

- native release 是 macOS 正常 release 编译参考，说明 Cargo/Rust workload 本身也不会线性打满 8 核。
- guest-aligned profile 用来和 guest 的 no-LTO/opt0/cgu256 演示 profile 对齐，说明同一构建任务在 host 上仍有明显并行空间。

因此，多核页可以自然引出下一页：

> 为什么 macOS 上同一构建任务可以有 `2.29x` 到 `2.93x`，而 StarryOS guest 内 jobs-only 只有 `1.24x`？这说明问题不只是 Cargo DAG 的并行宽度，还包括 guest OS 的进程、文件系统、同步、调度唤醒和虚拟化路径成本。

## 9. 为什么 8 核总是打不满

### 9.1 CPU 曲线证据

完整 `SMP=8`、`cargo jobs=8` 的 QEMU CPU 采样窗口为 `551s`，构建返回 `rc=0`。macOS `top` 口径中，一个满载 host core 约等于 `100%`；所以 8 个 vCPU 都满载时，QEMU 进程应接近 `800%`。

完整样本结果：

| 指标 | 数值 |
| --- | ---: |
| 编译窗口 | `551s` |
| QEMU 进程 CPU 均值 | 约 `391%` |
| QEMU 进程 CPU 峰值 | 约 `746%` |
| 等价忙 vCPU 均值 | `3.91` |
| 等价忙 vCPU 峰值 | `7.46` |
| 8 vCPU 归一化均值 | `48.92%` |
| 8 vCPU 归一化中位数 | `54.63%` |
| 8 vCPU 归一化峰值 | `93.25%` |
| 达到 75% 以上秒数 | `39s` |
| 达到 90% 以上秒数 | `1s` |

这张图说明：8 核不是没有启动，峰值能到接近 8 个 vCPU；但它不会长期保持满载，平均大约只忙了 4 个 vCPU。

### 9.2 Cargo DAG 的限制

`cargo -j8` 表示“最多同时跑 8 个 job”，不表示任意时刻都有 8 个可运行 job。Rust 编译有依赖 DAG：一个 crate 必须等依赖 artifact 完成后才能开始；build script、proc-macro、核心库、配置生成和最终链接都会形成阶段门槛。

已有 Cargo timing 证据显示：

- 完整 PASS 日志里有大量 compile start / artifact finish 波形，而不是 8 个长任务从头跑到尾。
- build script 在早期很密集，很多任务短但会阻塞下游 crate。
- 最后阶段新增 compile start 变少，只剩少量 artifact finish，尾部天然变窄。

所以 `rustc` 不应该被简单说成“小任务”。更准确的说法是：单个 `rustc` 可以不短，但 Cargo DAG 在某些时刻只释放少数可运行 `rustc`；同时又存在很多 build script、proc-macro、metadata、fingerprint、link 等短阶段和串行门槛。

### 9.3 guest OS 路径成本

StarryOS guest 内的 Cargo build 会反复经过这些路径：

```text
fork/clone/exec/wait
pipe/eventfd/futex
open/read/write/rename/unlink/stat
VFS/path lookup/tmpfs/rsext4
page fault/usercopy/page allocation
task wakeup/runqueue/IPI
process teardown/fd cleanup
```

这些路径不是纯 CPU-bound 循环。并发升高后，共享锁、目录元数据、文件写入、wait queue、runqueue 和页分配都会放大 wall time。PR `#879` 和 `#926` 就是从多核压力里拆出来的同步/唤醒问题。

这里要谨慎：CPU 占用高不一定等于有效编译，也可能包含 guest kernel、QEMU、同步等待、锁竞争甚至某些自旋成本。但“是否自旋”需要 PC sampling、锁统计或更细 syscall/trace 证据；目前报告里最稳妥的结论是：

> 高 CPU 只能说明 QEMU/guest 确实在消耗 host core，不能直接证明这些 CPU 都在做有效 rustc codegen。当前证据支持“Cargo DAG 不长期满 8 核 + guest OS 共享路径放大开销”的解释；不把主要慢因直接归结为自旋。

### 9.4 macOS 对照的意义

macOS host native release `-j8` 的实际 CPU 也没有持续打满 8 核：

| 指标 | macOS native `-j8` |
| --- | ---: |
| wall time | `42s` |
| 进程树 CPU 均值 | `112.7%` |
| 进程树 CPU 峰值 | `299.8%` |
| 等价忙 host core 均值 | `1.13` |
| 等价忙 host core 峰值 | `3.00` |
| 8 核归一化均值 | `14.1%` |
| 8 核归一化峰值 | `37.5%` |

这说明“Cargo 不长期打满 8 核”在 macOS 上也成立。但 macOS 仍能从 `96s` 降到 `42s`，加速 `2.29x`。StarryOS guest 的 jobs-only 只有 `1.24x`，说明 guest OS / QEMU 路径成本进一步压低了并行收益。

可以用这个公式概括：

```text
总时间 =
  Cargo DAG critical path
  + build script / proc-macro / link / LTO 等阶段门槛
  + guest fork/exec/wait/futex 成本
  + guest VFS/FS/metadata/write 成本
  + guest scheduler/wakeup/runqueue 成本
  + QEMU/HVF guest-userland 边界成本
```

最终结论不是“8 核没开”，而是：

> `-smp 8` 和 `cargo -j8` 提高的是并发上限，不保证 8 核持续满载。Cargo/Rust 本身有依赖关键路径，StarryOS guest 又把进程、文件系统、同步和调度成本放大，所以平均能用到约一半 vCPU，但 wall time 只缩短了一点。

## 10. 复现材料与 demo 脚本

最终展示材料里，demo 脚本分成三类。

### 10.1 live demo 五个入口

目录：`showtime-2/final/live-demo/`

| 脚本 | 用途 |
| --- | --- |
| `01-build-starryos` | 在 host 上构建 StarryOS kernel，准备可启动镜像。 |
| `02-guest-build-starryos` | 启动 AArch64/HVF StarryOS guest，在 guest 内编译 StarryOS。 |
| `03-test-kernel-result` | 启动测试 kernel，验证 userland 能进入并打印 PASS marker。 |
| `04-try-kernel` | 手动试启动指定 kernel，便于现场演示。 |
| `05-speed-ratios` | 汇总或重跑 demo benchmark、guest 实际编译、macOS host 编译的 `1 -> 8` 并行测速比。 |

`05-speed-ratios` 对应三种测速口径：

1. demo benchmark 的 `1` 核 vs `8` 核。
2. StarryOS guest 实际编译的 `1` 核 vs `8` 核。
3. macOS 宿主编译的 `1` 核 vs `8` 核。

### 10.2 CPU 曲线脚本

目录：`showtime-2/scripts/` 与 `showtime-2/final/cpu-util/`

| 脚本/文件 | 用途 |
| --- | --- |
| `run-hvf-starryos-smp8-hostcpu-second.sh` | 跑完整 guest `SMP=8` build，并按秒采集 QEMU CPU。 |
| `monitor-qemu-top-cpu.sh` | 模拟“另一个终端跑 top 看 qemu 进程”的采集方式。 |
| `extract-hvf-host-cpu-util.py` | 从 QEMU CPU time / top 采样中提取归一化 CPU 曲线。 |
| `run-host-build-cpu-curve.py` | 采集 macOS host native/guest-aligned 构建的进程树 CPU 曲线。 |
| `smp8-j8-fullcpu-occupancy-time.svg/png` | guest 8 核完整过程 CPU 利用率-time 图。 |
| `host-vs-guest-smp8-normalized-cpu.svg` | guest 与 host CPU 曲线对照。 |
| `macos-host-native-release-j1-vs-j8-cpu.svg` | macOS native release `-j1` 与 `-j8` 对照图。 |

这部分回答了之前的问题：可以一个终端跑 8 核编译，另一个终端看 `top` 里的 QEMU 进程 CPU；最终图就是把这种采样自动化、秒级保存、再归一化成曲线。

### 10.3 PPT 与报告材料

最终材料集中在 `showtime-2/final/`：

| 文件 | 用途 |
| --- | --- |
| `biglab-b-final-report-yang-kaisen.md` | 完整报告母稿。 |
| `biglab-b-final-ppt-outline-yang-kaisen.md` | PPT 内容规划和口播稿。 |
| `biglab-b-final-yang-kaisen.pptx/pdf` | 完整展示版。 |
| `biglab-b-final-yang-kaisen-minimal.pptx/pdf` | 简约答辩版，优先用于正式展示。 |
| `Kaisen-report-fixed.pptx/pdf` | 基于旧版 PPT 修补后的材料。 |
| `cpu-util/parallelism-analysis.md` | CPU 曲线和并行受限分析。 |

## 11. PR `#984`：macOS HVF self-build app 收尾

`#984` 的目标是把 macOS/HVF self-build 路线整理成上游可复现的 app/docs，而不是提交本地大文件或 showtime 日志。

PR：<https://github.com/rcore-os/tgoskits/pull/984>

整理时状态：

| 项目 | 状态 |
| --- | --- |
| 标题 | `docs(starry): add macOS HVF self-build app` |
| base | `dev` |
| head | `app/starry-macos-selfbuild` |
| state | `OPEN` |
| draft | `false` |
| mergeable | `MERGEABLE` |
| merge state | `CLEAN` |
| CI | `24` success / `25` skipped / `0` failed |

本次处理过两类问题：

1. 同步最新 `upstream/dev`，解决 PR 相对目标分支的冲突，提交 `1de953390 merge: sync app selfbuild with dev`。
2. 清掉无关 diff，把 `apps/starry/qemu/rust-hello/qemu-loongarch64.toml` 恢复到 `dev` 口径，提交 `313aa071f test(starry): keep rust hello loongarch config unchanged`。

最终 PR diff 只保留复现相关文件：

```text
apps/starry/README.md
apps/starry/macos-selfbuild/README.md
apps/starry/macos-selfbuild/RESULTS.md
apps/starry/macos-selfbuild/build-aarch64-unknown-none-softfloat.toml
apps/starry/macos-selfbuild/check_rootfs.sh
apps/starry/macos-selfbuild/guest-selfbuild.sh
apps/starry/macos-selfbuild/prepare_rootfs.sh
apps/starry/macos-selfbuild/qemu-aarch64-hvf.toml
apps/starry/macos-selfbuild/run_selfbuild.sh
```

这个 PR 可以作为“展示材料/复现说明”的收尾成果：它把本地能跑的 macOS/HVF self-build 路线整理到 TGOSKit 的 app 目录里，并且 CI clean、mergeable clean。

## 12. 过程汇报口播稿

这一段可以直接放报告“过程”小节，也可以作为答辩时的 2 到 3 分钟口播。

> 我的 BigLab-B 不是一开始就直接跑 8 核自举编译，而是先从基础训练和 OS 问题拆解开始。BigLab-A 里我完成了 rCore tutorial 的任务切换、地址空间、进程、文件系统和同步相关章节；BigLab-B Task 1 完成了 tg-arceos-tutorial 的 5 个 exercise，补齐 no_std Rust、allocator、RAMFS/VFS、sysmap 和 QEMU 调试基础。
>
> Task 2 开始后，我把目标定成一个真实 workload：让 StarryOS 在 guest 内编译 StarryOS。这个目标会自然触发 Linux ABI、文件系统、futex、usercopy、SMP 调度和唤醒问题。我的方法是先用 AI 辅助形成固定闭环：同步上游 dev、构造复现、缩短反馈、定位 OS bug、拆成小 PR、加 test-suit、本地验证，再等 GitHub Actions。最终合入了 futex、vfork、socket、rsext4、direct device、SMP topology、RISC-V hwprobe、tmpfs rename/exec、teardown、RawMutex、file syscall context、axtask wakeup 等方向的 PR。
>
> self-build 早期走 RISC-V TCG 路线，在 Docker/Linux/Alpine/RISC-V 环境里跑。这个路线更接近常规 RISC-V 目标，但反馈很慢；QEMU TCG 翻译开销大，带日志一次可能到 6 小时，不打重日志也约 100 分钟。于是我先把日志改成高信号 marker，并把发现的问题拆成 OS PR。后面为了做多核性能分析，我把主反馈路线迁移到 Apple Silicon 上的 AArch64/HVF，利用硬件虚拟化把反馈缩短到分钟级。
>
> 多核阶段我跑通了 StarryOS guest 内完整 self-build，并把速度从早期 `951s` 调到当前最好 `331s`，端到端调优收益是 `2.87x`。但如果只看同一 profile 下 guest jobs 从 1 到 8，结果是 `422s -> 341s`，只有 `1.24x`。作为对照，macOS host native release 是 `96s -> 42s = 2.29x`，guest-aligned profile 是 `85s -> 29s = 2.93x`。这说明同一 Cargo workload 本身有并行空间，但 StarryOS guest 的进程、文件系统、同步、调度唤醒和 QEMU/HVF 路径成本显著压低了并行收益。
>
> 我还做了秒级 CPU 曲线。`SMP=8`、`cargo jobs=8` 的完整 guest build 采样窗口是 `551s`，QEMU 进程 CPU 平均约 `391%`，等价平均忙 `3.91` 个 vCPU，峰值能到 `7.46` 个 vCPU，但超过 75% 的时间只有 `39s`，超过 90% 只有 `1s`。所以结论不是 8 核没有启动，而是 `-smp 8` 和 `-j8` 只提高并发上限；Cargo DAG、build script、proc-macro、link 尾部以及 guest OS 共享路径共同决定它不会线性加速。
>
> 最后，我把复现路线整理成 live demo 脚本、CPU 曲线脚本、PPT 和 PR `#984`。`#984` 把 macOS/HVF self-build app 放入 TGOSKit，当前 PR 是 `CLEAN`、`MERGEABLE`，CI 为 `24` success、`25` skipped、`0` failed。这个过程的核心收获是：真实 workload 不只是展示结果，它能反向推动 OS 语义修复；性能分析也不能只看一个加速比，而要区分端到端调优、严格 jobs-only、host 对照和 guest OS 成本。

## 13. 建议与后续思考

最后一页不需要写得像注释，可以保留核心判断：

1. 真实 workload 是 OS 教学和验证的放大镜。单个 syscall 测试能证明局部语义，StarryOS self-build 这类 workload 能同时压到进程、文件系统、同步、调度和内存路径。
2. AI 最适合做“反馈闭环加速器”，不是替代 review。有效的模式是让 AI 帮助缩短复现、整理日志、提出候选根因和写 PR body，但最终仍要用 test-suit、CI 和最小补丁约束。
3. 性能优化必须分口径。`951s -> 331s` 是端到端调优收益，`422s -> 341s` 是 guest jobs-only，`96s -> 42s` 是 macOS native 对照；混在一起会得出错误结论。
4. 后续最值得继续拆的是 guest OS 共享路径：rsext4 小文件写入/同步策略、VFS metadata、wait/futex 唤醒、进程 teardown、feature gating 和更细粒度 CPU/锁统计。
5. M6/self-build 后续应继续坚持“确认 OS bug 就拆 PR”的原则。复现脚本、rootfs 和日志用于证明问题；真正进入上游的应该是根因清楚、scope 小、测试明确的 OS 行为修复。
