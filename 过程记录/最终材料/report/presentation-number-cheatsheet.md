# StarryOS 汇报数字速记卡

更新时间：2026-05-29 18:00 CST

## 先讲 8 个数字

| 数字 | 现场讲法 |
| --- | --- |
| `331s` | 当前最快：8 核 AArch64/HVF StarryOS guest 内完整 `cargo build -j8` 编译 StarryOS PASS。 |
| `951s -> 331s` | guest 端到端真正收益：从最慢 baseline 到当前最快 tuned best，`2.87x`。 |
| `422s -> 341s` | guest 编译并行收益：同 optional-ddebug profile 只改 `jobs=1 -> jobs=8`，`1.24x`。 |
| `85s -> 29s` | host 对齐参考：同源码、同 AArch64/SMP8 StarryOS kernel 配置、同 no-LTO/opt0/cgu256 profile，只把 cargo/rustc 从 guest 移到 host，`2.93x`。 |
| `642s -> 427s` | 链接/串行尾段收益：关闭 LTO，再用 `opt-level=0` 和 `codegen-units=256`，合计 `1.50x`；不是独立 link-only benchmark。 |
| `12` 个已合入 PR | `#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926`，都已合入 `rcore-os/tgoskits:dev`。 |
| `20/11/5/3s` | 1000 次 `fork+exec+wait`，`jobs=1/2/4/8` 分别为 `20/11/5/3s`；8 路相对 1 路是 `6.67x`，证明 OS 进程创建/等待短链路能扩展。 |
| `27/22/27/32/32s` | rustc build-script 小任务，`jobs=1/2/4/6/8` 分别为 `27/22/27/32/32-33s`；小任务甜点在 2，并发过量会被 OS/SMP/FS 开销反吃。 |

现场最稳的一句话：**8 核 guest self-build 已经完成，最快 `331s`；相对最慢 guest baseline `951s` 是 `2.87x`。严格同 profile 只改 guest jobs 是 `422s -> 341s = 1.24x`；宿主对齐参考是同一 StarryOS AArch64/SMP8 kernel 构建任务，只把 cargo/rustc 从 guest 移到 host，`85s -> 29s = 2.93x`，说明 Cargo 图本身有并行空间；host/guest 差距来自 guest 内 OS/FS/SMP/QEMU 成本；链接/LTO/codegen 串行尾段从 `642s` 压到 `427s`，是 `1.50x`。**

## 速度演进

```text
951s baseline
  -> 642s  默认完整 release
  -> 515s  LTO off
  -> 450s  opt-level=0
  -> 427s  codegen-units=256
  -> 379s  axtask wakeup/runqueue
  -> 357s  no-dynamic-debug + explicit IPI
  -> 341s  ddebug optional
  -> 331s  tuned local best
```

## 编译时长-内核数表达式

```text
T_build(N) = T_std/cache
           + T_serial(link/LTO/build.rs)
           + T_parallel_crates / N
           + T_fs(N)
           + T_smp(N)
           + T_wait(N)
```

汇报重点：不是只把 `-smp` 开大，而是逐步压 `T_fs`、`T_serial`、`T_smp` 和 `T_wait`。没有接近 4x 的原因已经量化，不是“没跑通”。

## 为什么不是 4x

| 证据 | 结论 |
| --- | --- |
| `core 256s / starryos bin 248s / compiler_builtins 245s / ax-hal 206s` | critical path 很长，最终 `starry-kernel` 本体只有 `17s`。 |
| `jobs=12: 609s` | 8 vCPU 上继续加 Cargo jobs 反而更慢。 |
| `331/338/349s tuned sweep` | 调优 sweep 的本地结果，说明继续加内部并行没有稳定收益；不把 `331s` 归因成单一开关。 |
| `cgu192: 358s` | `codegen-units=256` 改成 `192` 变慢，说明当前 `cgu256` 更适合这个 profile。 |
| `fork/exec wave 1000: 20/11/5/3s` | 纯进程创建/执行/等待在 8 核 guest 下最高 `6.67x`，说明不是“StarryOS 多核完全无效”。 |
| `display+DRM gating: 338s` | 真正剪掉 `ax-display/ax-driver-display` 且把 DRM 代码一起 feature-gate 后完整 PASS；结构更干净，但慢于最好 `331s`。 |
| `net-ng de-legacy: 346s` | `ax-feat/net-ng` 解耦 legacy `ax-net` 后完整 PASS，`ax-net` 不再编译；结构正确，但慢于 `331s`。 |
| `display+net-ng: 359s` | 两个 feature graph cleanup 叠加后 crate 数到 `279`，但更慢，说明继续小修依赖图不是 4x 主线。 |
| `rustc wave 24: 27/22/27/32/32s` | 24 个小 build-script 的 `jobs=1/2/4/6/8` 为 `27/22/27/32/32-33s`；2 路最快，8 路反而慢。 |
| `rustc wave 64: 89s` | 64 个 direct rustc build-script 小任务在 SMP8/jobs8 下 PASS，但它不是 full build 的主加速来源。 |
| `cargo check: 574s` | full check 不能替代 full build 做短反馈。 |
| `build-override: 663s` | build-script/proc-macro profile override 是负优化。 |
| `BUILD_STD=none: 426s` | sysroot 秒级预检有用，但跳过 build-std 不是主提速点。 |

## 30 秒口播

> 我们已经在 StarryOS guest 里真实完成了 8 核 `cargo build -j8` 编译 StarryOS，当前最快是 `331s`。相比最慢 guest baseline `951s`，端到端提升是 `2.87x`；严格同 profile 只改 guest jobs 是 `422s -> 341s = 1.24x`；宿主对齐参考使用同一源码、同一 AArch64/SMP8 kernel 配置和同一 release profile，只把 cargo/rustc 从 guest 移到 host，结果是 `85s -> 29s = 2.93x`。这证明 Cargo 图有并行空间，而 guest 内的 OS/FS/SMP/QEMU 成本限制了 full build 加速。链接/LTO/codegen 串行尾段从 `642s` 压到 `427s`，是 `1.50x`。

## 最新判断

display-gating 和 net-ng de-legacy 已经复测清楚：它们能清理 feature graph，并且完整 build PASS，但不是 4x 主性能杠杆。#926 已合入，remote task/wakeup IPI kick 是本轮 SMP 前进性修复的一部分。剩余瓶颈更像 Cargo critical path、load balance/idle pull、以及更细粒度的 build graph/OS 等待成本。

2026-05-26 01:28 追加：为了避免只靠完整 build 等 5 分钟以上，补了 direct rustc build-script wave 短链路。`CRATE_COUNT=24` 时，`jobs=1/2/4/6/8` 分别为 `27/22/27/32/32-33s`；`CRATE_COUNT=64/jobs=8` 为 `89s` PASS。这个数字很好讲：StarryOS 不是不能并行，2 路确实更快；但小 crate/build.rs 这种短任务超过 2 路后会被 fork/exec、wait、pipe、文件写入、runqueue 和 SMP 锁成本吞掉，所以 4x 的关键不在继续堆 `-j`，而在压 `T_wait(N)+T_smp(N)+T_fs(N)`。同时 CPU monitor 暴露 `/proc/stat` aggregate CPU 计数会在短命进程退出后倒退，已在干净分支做成 `fix(starry): keep /proc/stat CPU counters monotonic` PR 候选，配套 `test-proc-stat-monotonic`。

2026-05-26 02:10 追加：补纯 OS 进程链路短基准，1000 次 `fork+exec+wait` 在同一 AArch64/HVF SMP8 guest 中 `jobs=1/2/4/8` 分别为 `20/11/5/3s`，对应 `1.82x/4.00x/6.67x`。这条是汇报里最硬的“多核确实能加速”证据：纯进程创建和等待路径能扩展，完整 cargo 没到 4x 不是因为多核完全无效，而是 rustc 小任务和完整 build graph 叠加了文件写入、pipe/wait、runqueue、锁竞争和串行尾段。

2026-05-29 追加：PR 状态按最终答辩口径收敛为 12 个已合入 PR：#692/#693/#694/#695/#800/#842/#843/#844/#878/#879/#885/#926。性能数字按三类汇报：端到端 `951/331=2.87x`，guest jobs-only `422/341=1.24x`，host 对齐参考 `85/29=2.93x`，链接/串行尾段 `642/427=1.50x`。host 对齐参考使用 `/Users/txc/code/Auto-OS/过程记录/最终材料/scripts/run-host-aligned-starryos-oracle.sh`，同样生成 AArch64/SMP8 StarryOS kernel axconfig，并采用和 guest 调优路径相同的 no-LTO/opt0/cgu256、slab/no-dynamic-debug profile；区别是 cargo/rustc 运行在 host OS，不进入 StarryOS guest。
