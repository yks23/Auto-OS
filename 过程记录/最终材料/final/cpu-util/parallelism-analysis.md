# SMP8 编译时间周期与并行受限分析

## 图

- 完整 551s 占用率-time 图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/smp8-j8-fullcpu-occupancy-time.svg`
- QEMU `top` 口径完整 CPU 图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.topcpu.svg`
- 8 vCPU 归一化完整 CPU 图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/smp8-j8-hostcpu1s-20260530T191559-fullcpu.svg`
- macOS 宿主 native-release `-j8` CPU 图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-native-release-aarch64-smp8-j8-20260530T170100-native-j8.svg`
- macOS 宿主 native-release `-j1` vs `-j8` CPU 图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/macos-host-native-release-j1-vs-j8-cpu.svg`
- 完整 457s Cargo 时间周期图：`/Users/txc/code/Auto-OS/过程记录/最终材料/final/cpu-util/smp8-j8-cargo-jsoncpu-20260524T233333.timeline.svg`

## 数据口径

`top` 图看的是宿主机上的 `qemu-system-aarch64` 进程 CPU。macOS 里一个满载 host core 约等于 `100%`；所以 `-smp 8` 的 VM 如果 8 个 vCPU 都跑满，QEMU 进程应接近 `800%`。图里的 `160%` 左右不是 160%/800% 打满，而是大约 `1.6` 个 host core 在忙。

完整采样已经跑完：`SMP=8`、`cargo jobs=8`，从 `BUILD-START` 到 `BUILD-END` 取 QEMU 进程 CPU time，构建 `rc=0`，编译窗口 `551s`。

完整样本结果：

- 编译窗口采样点：`543`
- 精确 1 秒区间：`535`
- QEMU 进程 CPU 均值：约 `391%`
- QEMU 进程 CPU 峰值：约 `746%`
- 等价忙 vCPU 均值：`3.91`
- 等价忙 vCPU 峰值：`7.46`
- 8 vCPU 归一化均值：`48.92%`
- 8 vCPU 归一化中位数：`54.63%`
- 8 vCPU 归一化峰值：`93.25%`
- 达到 8 vCPU 75% 以上的秒数：`39`
- 达到 8 vCPU 90% 以上的秒数：`1`

## macOS 宿主对照

这里要修正：上一版我把 `guest-aligned` setting 当成“macOS 正常编译”讲了，这是不严谨的。`guest-aligned` 设置了：

```text
CARGO_PROFILE_RELEASE_LTO=false
CARGO_PROFILE_RELEASE_OPT_LEVEL=0
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256
```

日志里也显示 `release profile [unoptimized]`。这只能用于和 guest 的演示/实验 profile 对齐，不能代表 macOS 正常 release 编译。

我重新在 macOS 宿主跑了 native release profile，也就是不设置上面这些 override，使用 `tgoskits/Cargo.toml` 里的 `[profile.release] lto = true` 和 Cargo 默认 release 优化：

```text
cargo build -p starryos --bin starryos
  --target aarch64-unknown-none-softfloat
  -Z build-std=core,alloc,compiler_builtins
  --features qemu,gic-v3,cntv-timer,smp
  --release
```

采样口径是 build runner 的进程树 `%CPU`，也就是 `cargo`、`rustc`、build script 等子进程的 top-style CPU 总和；不统计无关宿主进程。

native-release 实际采样：

- macOS host native `-j1`：PASS，`96s`
- macOS host native `-j8`：PASS，`42s`
- native `-j8` 相对 `-j1`：约 `2.29x`
- native `-j8` 进程树 CPU 均值：`112.7%`
- native `-j8` 进程树 CPU 峰值：`299.8%`
- native `-j8` 等价忙 host core 均值：`1.13`
- native `-j8` 等价忙 host core 峰值：`3.00`
- native `-j8` 8 核归一化均值：`14.1%`
- native `-j8` 8 核归一化峰值：`37.5%`
- native `-j8` 峰值 `rustc` 进程数：`8`

保留下来的 `guest-aligned` 数据只作为对照：

- aligned `-j1`：`85s`
- aligned `-j8` 历史干净 run：`29s`
- aligned `-j8` 相对 `-j1`：约 `2.93x`
- 但 aligned 的 `-j8` 是 `release profile [unoptimized]`，不能和 native release 混成一个结论。

也就是说，macOS 宿主上的同一 Cargo DAG 也没有把 8 核持续打满；native `-j8` 峰值约 3 个 core，均值约 1.13 个 core。但它仍能在 `42s` 完成，native `-j1` 是 `96s`。这个对照很关键：`-j8` 不等于 800% CPU，这在 macOS 上也成立；guest 的问题不只是“CPU 曲线没到 800%”，而是类似并行宽度下，每推进一个 crate/artifact 的成本被 StarryOS guest 路径显著放大。

## 完整时间周期图说明

完整 457s 图使用的是已有完整 PASS 日志里的 Cargo JSON timing。它不声称是 CPU 利用率，而是解释编译工作负载在时间上的展开方式：

- 总耗时：`457s`
- Cargo jobs：`8`
- compile start 事件：`228`
- artifact finish 事件：`258`
- build script executed 事件：`27`
- compile start 峰值桶：`390-420s`，`24` 个 start
- artifact finish 峰值桶：`330-360s`，`25` 个 finish
- 最后 120s 仍有 `50` 个 compile start 和 `65` 个 artifact finish

这张图能说明：build 不是一开始就有 8 个长任务持续跑满，而是很多短 crate、build script、proc-macro 和依赖解锁事件构成的波形。

## 为什么并行加不起来

1. Cargo 的依赖 DAG 有天然串行边界。

   `-j8` 只表示最多同时跑 8 个 job，不表示任意时刻都有 8 个可运行 job。一个 crate 必须等依赖 artifact 完成后才能开始；proc-macro、build script、核心库、配置生成这类节点会卡住后续一批 crate。

2. 早期 build script 和 proc-macro 会形成门槛。

   前 180s 中 build script 很密集，30s 桶里分别出现 `4,1,4,4,4,5` 次 build-script executed。这些任务本身往往短，但会阻塞下游 crate；它们制造的是阶段门槛，不是长时间 CPU 饱和。

3. 很多任务太短，调度和进程成本占比高。

   Cargo/Rust 会产生大量短命 `rustc`、build script、helper 进程。guest OS 要为这些任务支付 fork/exec、wait、pipe、文件元数据查询、target-dir 写入、进程回收等成本。并发数升高后，这些成本不会消失，反而可能放大锁竞争和 cache 抖动。

4. guest OS 的共享路径限制了可扩展性。

   这个 workload 压的是 StarryOS 的调度、futex/wait、VFS/path lookup、ext4/tmpfs 写入、页分配、进程 teardown 等路径。它不是单纯的 8 个 CPU-bound 循环；大量操作会经过共享锁、全局结构、目录/文件系统元数据和唤醒路径。

5. 尾部变窄，额外核心无事可做。

   `420-450s` 只新增 `8` 个 compile start，但完成 `16` 个 artifact；`450-457s` 没有新的 compile start，只剩最后 `2` 个 artifact finish。尾部阶段已经不是宽并行问题，多出来的 vCPU 无法缩短依赖链上的最后节点。

6. 单个 rustc 也不是 8 核满载模型。

   单个 `rustc` 有前端分析、宏展开、元数据、link/emit 等串行或有限并行阶段。`CARGO_BUILD_JOBS=8` 可以并发多个 `rustc`，但当 Cargo DAG 当前只暴露 1-2 个重任务时，QEMU 进程自然只吃到约 1-2 个 host core。

7. macOS 对照证明“DAG 不满 8 核”和“guest 慢”是两件事。

   macOS host native `-j8` 的实际 CPU 均值只有 `1.13` 个 core，峰值约 `3.00` 个 core，但它仍能在 `42s` 完成；native `-j1` 是 `96s`。StarryOS guest 的完整 PASS 是 `457s`。因此，不能只把问题解释成 Cargo 没有 8 个可运行任务；更准确地说，Cargo DAG 本来就不会长期打满 8 核，而 guest OS 的 fork/exec、wait/futex、VFS、文件写入、页分配、进程回收和虚拟化开销把每个阶段的 wall time 拉长了。

## 结论

`-smp 8` 和 `-j8` 提高的是并发上限，不保证 8 核持续满载。当前证据更符合这个模型：

```text
总时间 = Cargo 依赖关键路径
       + guest OS 进程/文件系统/同步开销
       + 短任务调度成本
       + 串行尾部
```

所以 8 核没有线性叠加，不是因为 QEMU 没给 8 个 vCPU，也不是 Cargo 参数没开，而是两层因素叠加：

1. workload 层：Cargo DAG、build script、proc-macro、短命 `rustc` 和尾部依赖链决定了它本来不会长期 8 核满载。
2. guest OS 层：StarryOS 上的进程、同步、VFS、文件系统和内存路径把这些短任务的非计算成本放大，导致相近 CPU 宽度下 wall time 明显长于 macOS host。
