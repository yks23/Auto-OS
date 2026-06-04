# 展示讲述顺序

下面这版更接近口头表达，不需要逐字念，但建议保持这个逻辑。

## 0. 开场

今天我展示的不是一个单独 patch，而是 StarryOS self-build 这条链路的完整整理：结果在哪里、怎么复现、证明了什么、还有哪些风险要继续拆。

这次最重要的进展是：单 CPU 的 M6 guest self-build 已经跑通。也就是说，StarryOS guest 内部跑了 Rust/Cargo workload，并且编译出了 StarryOS kernel。

## 1. 为什么要分单核和多核

我把材料放在 `Auto-OS/showtime` 下，分成两条线：

- `single-cpu`：稳定基线，证明 guest 能编译出 kernel，记录 binary、checksum 和完整日志。
- `multi-cpu`：加速实验，验证多核 guest cargo build 是否真的能降低 wall time。

这么分是因为多核实验里变量很多。如果没有单核 baseline，后面看到 panic、速度变化、文件系统问题时，很难判断到底是哪一层的问题。

## 2. 单核 M6 已经跑通

这次单核配置是：

- `riscv64-qemu-virt`
- `-smp 1`
- `-accel tcg,thread=single`
- guest 内 `cargo build --release`

完整日志在：

```text
过程记录/早期记录/single-cpu/logs/m6-selfbuild-guest-pass.log
```

关键成功行是：

```text
Finished `release` profile [optimized] target(s) in 132m 59s
===M6-SELFBUILD-PASS===
```

编译出来的产物也已经放进：

```text
过程记录/早期记录/single-cpu/binaries/riscv64-qemu-virt/
```

里面有 `.elf`、`.bin`、`SHA256SUMS` 和 `build-info.md`。

## 3. 这件事证明什么

它证明 StarryOS guest 可以支撑足够复杂的 Rust/Cargo 编译 workload，最终在 guest 内产出 StarryOS kernel。

但我会把边界讲清楚：

- 它证明的是 guest self-build pass。
- 新 `.bin` 已经和原本正确编译的 reference kernel 做了同环境 A/B boot smoke：同一个 Linux QEMU、同一个 rootfs、同一套启动参数，只替换 `-kernel`，两边都能进入 StarryOS userland/M6 init，并在 resume 模式打印 PASS。
- 复杂用户态 smoke 只作为“内核能承载重用户态程序”的旁证，不作为多核汇报主线。
- 它也不等于多核已经稳定。

所以后续多核汇报只围绕内核实现：调度、迁移、同步和文件系统路径。

## 4. 严谨性：A/B 对比

这里我会专门强调验证方式：不是只把 guest-built kernel 启动一次，而是拿 reference kernel 做对照。

两次运行共同条件完全一样：

- Linux 容器里的 QEMU。
- fsck 后的同一个 rootfs。
- `-smp 1, tcg,thread=single`。
- snapshot 模式，避免污染镜像。

不同的只有 `-kernel`：

- reference: `.guest-runs/riscv64-m6/starry-up1.bin`。
- guest-built: `过程记录/早期记录/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin`。

判据也一致：进入 StarryOS userland，找到 rootfs 内已经完成的 StarryOS ELF，打印 `===M6-SELFBUILD-PASS===`，并且没有 `panic/trap/FATAL/error`。这个对照能说明 guest self-build 产物在当前 smoke 上和原本正确编译的 kernel 行为一致。

## 5. 本次额外发现的问题

编译本身是成功的，但在 host 侧读回 checkpoint tar 时发现了文件系统一致性问题。

现象是 `/opt/tgoskits/.m6-checkpoints/target.tar` 直接读回会失败，`debugfs/e2fsck` 显示 duplicate extent 和 multiply-claimed blocks。

我没有在原始 rootfs 上修，而是在复制出来的镜像上 fsck，然后把最终 ELF/bin 提取出来放到 showtime。

这说明两个结论要分开：

- cargo build 成功是真的。
- checkpoint 大文件写回/读回路径需要单独做一个文件系统 regression。

## 6. PR 线索

最近几个 PR 我也整理进了 `过程记录/早期记录/single-cpu/docs/bugfixes.md`：

- #692 robust futex cleanup：线程退出时 robust-list 坏指针不能拖垮退出路径，pending futex 要单独清理；这次还把测例按 Linux ABI 拆成 pending cleanup 和 bad-head tolerance，避免测试预期过强。
- #693 vfork/child-stack clone：传统 vfork 仍要阻塞父进程，但 `CLONE_VM|CLONE_VFORK` 带私有 child stack 的 posix_spawn 类路径不能被内核强行阻塞，否则可能死锁。
- #694 IPv4-mapped IPv6 socket：AF_INET6 socket 使用 `::ffff:127.0.0.1` 时走 IPv4 backend，但对用户态仍要报告 IPv6 sockaddr 语义。
- #695 rsext4 inode bitmap：ext4 block group 的 inode bitmap 未初始化时，allocator 需要初始化并继续分配，不能直接跳过可用 inode 容量。

讲的时候重点不是“我改了很多文件”，而是每个 PR 都应该能回答四个问题：为什么错、怎么修、哪个测例覆盖、CI 当前状态是什么。

目前 #692 新 CI 已经触发，#695 已观察到 CI 绿；#693 和 #694 的旧 CI 里有取消或架构相关失败，需要区分是本 PR 问题、公共 runner 取消，还是要重跑确认。

## 7. 多核进展：先正确，再加速

多核这条线的目标不是“启动多个 CPU 但编译还是串行”，而是先证明 StarryOS 的 SMP 内核能长时间支撑真实用户态 workload，然后再逐步放大并行度，最后才谈速度倍数。

现在 hello-world build 有一组初始信号：

- 单核 `-j1` 大约 176 秒。
- 四核 `-j4` 大约 62 秒。

这是大约 2.8 倍的 speedup，说明方向有价值。但它还只是小 workload，需要继续扩大样本和压力。

最新用 guest-built 8-HART kernel 复跑 raw CPU benchmark，也能看到明确加速：同一个 kernel、rootfs 和 workload，只切 `tcg,thread=single/multi`，workers=4 从 `769171us` 到 `297609us`，约 `2.58x`；workers=8 从 `764731us` 到 `310878us`，约 `2.46x`。旧的 4-HART 稳定样本最好是 `3.17x`。

M6 这条线现在有几组证据：

- v19：`SMP=4 + jobs=1` 的完整 selfbuild 跑了很久，越过 `thiserror`、`ax-task`、`ax-driver`，没有 guest panic；最后是 host 把 QEMU kill 掉，所以不能算 full PASS，但能证明内核已经撑住了很长一段真实 workload。
- v20：`SMP=4 + jobs=2` 的 subset smoke 通过，日志里有 `nproc=4 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2` 和 `===M6-SELFBUILD-SUBSET-PASS===`。
- v21：`SMP=4 + jobs=2` 的 full early-pressure 进入真实 cargo build，跑到 `syn v2.0.117`，没有 panic 或 SIGSEGV，但后续 heartbeat 消失并触发 stall detector。
- v22：早期 `starry-kernel` lib 阶段已经带 `--features smp` 编译，heartbeat 继续推进到 `syn v1.0.109` 后触发 `StoreFault`，这给了一个可以继续缩小的具体内核 fault。
- v27：在新的上游 dev 基线继续 `SMP=4 + jobs=2`，跑到 `quote v1.0.45`，通过 mutex `track_caller` 把 panic 定位到 `task/user.rs:38`，也就是用户 page fault 时获取 address-space mutex 的地方。
- v28：把 `RawMutex` unlock 从直接 owner handoff 改成先清 owner 再 wake waiter 后，已经越过 v27 的 `quote` 失败点，进入 `quote`/`syn` 的 rustc 编译。这个结果还不是 full PASS，但已经说明问题不是脚本，而是内核同步语义。
- v29：切到可诊断的 `platformdiag` kernel，用 host QEMU 的 `SMP=4 + thread=single + jobs=2` 跑真实 `starry-kernel` guest build。前置的 scheduler smoke 和 M6 subset 都通过；tmpfs cargo-home 版本暴露了 `chrono` lookup 问题，所以当前用直接 rootfs cargo-home 保持正确性验证。第一轮被外层 1800 秒 expect 超时杀掉，当时 guest 还在 `alloc/clap_builder`，没有 panic/trap；现在已经把 runner 改成 8 小时，并且只在最终 PASS 后 `sync` 再退出。
- v30：用 host QEMU 启动 `SMP=8 + thread=multi` 的 StarryOS guest，保守地保持 `CARGO_BUILD_JOBS=1/RAYON_NUM_THREADS=1`，完成最终 `starryos` pass2 编译，耗时 `131m02s`，串口提取出的 ELF sha256 是 `65336ca8...9d10a07`。随后只替换 `-kernel` 为 guest-built `.bin`，用 `SMP=8 + thread=single + snapshot rootfs` boot smoke，进入 userland 并打印 `===BOOT-SMOKE-PASS===`。
- v31：真实 M6 cargo 阶段已经看到加速。`SMP=8 + thread=multi + jobs=1` 的 `starry-kernel lib` 是 `187m44s`；`jobs=4` 是 `84m16s`，约 `2.23x`。这个不能讲成 full PASS，因为后续 pass1 仍然遇到 guest cargo/rustc `Segmentation fault`。
- v32：回到 correctness 模式，使用 `SMP=8 + thread=single + jobs=4` 的 pass2 snapshot 把问题收敛到内核。第一层是 `access_user_memory` 被非 StarryOS thread context 调用，现在改成 access error 而不是 kernel panic；第二层是 `RawMutex` 直接 handoff owner 导致 address-space lock false self-owner，现在改成先释放 owner 再 wake waiter。后续又暴露了零长度 usercopy 和 task-owned mutex guard 可跨任务释放的问题，所以补成零长度 copy no-op、mutex guard non-Send。修复版已经越过旧的 72s/149s/223s/846s 崩溃窗口，跑到 1265s host 上限才停。

这说明多核不是“没起来”：8-HART guest 已经能产出并启动 StarryOS kernel。剩下真正要攻的是 cargo `jobs>1` 的并行正确性和速度倍数，它会继续挑战 scheduler、公平性、heartbeat 响应，以及页表/内存访问路径。

## 8. 多核暴露出的内核问题和修正

第一类问题是用户态 timer interrupt 后没有明确让出 CPU。

现象是 host 侧 QEMU 还在吃 CPU，但 guest 侧 heartbeat 长时间不推进。原因是用户态通过 `uctx.run()` 返回 `ReturnReason::Interrupt` 后，只回到用户循环，原来没有把这个 timer 点显式交给调度器。修正是在这个分支里调用 `ax_task::yield_now()`，让 CPU-bound 用户进程不能一直占着 run queue。

第二类问题是用户任务跨 CPU 迁移。

我尝试让 blocked task 直接跨 run queue 做负载均衡后，出现过一次很典型的 panic：syscall 路径里 `current().as_thread()` 看到了 kernel task。这个说明 StarryOS 的用户线程上下文和 `TaskExt` 当前还不是完全 migration-safe。现在的策略是：用户态运行期间 pin 到当前 CPU，blocked 用户任务唤醒时先回到原 CPU；不带用户态上下文的 kernel task 才走更自由的负载均衡。

第三类问题是 run queue 本身缺少负载信号。

现在每个 CPU run queue 会维护 load，后续非 pinned 的 kernel task 可以按负载选择目标 CPU。用户任务先保持亲和性，这是一种 correctness-first 的策略；等用户线程上下文迁移语义补齐后，再扩大迁移范围。

第四类是诊断能力。

这类长跑实验不能只靠“最后 panic 了”。我给 preempt/block 相关路径加了 `track_caller` 和 caller 记录，后续如果多核调度再次出错，能更快定位是哪个内核调用点把状态带坏。

第五类是 feature wiring。

原来 `starry-kernel` 自己没有 `smp` feature，所以 guest 的早期 `[2] cargo build -p starry-kernel` 阶段没有直接编译 `ax-task/smp` 的 run queue 代码，要等后面的 `starryos --features smp` 才覆盖，反馈太晚。现在我加了 `smp = ["ax-feat/smp"]`，并且宿主离线 `cargo check -p starry-kernel --features smp` 已通过；v22 注入后也已经打印 `[2] starry-kernel: enabling workspace feature smp`，说明早期 lib 阶段就能覆盖 SMP 调度路径。后续 v22 暴露的 `StoreFault` 也因此是有效的 OS/kernel 反馈，不是 feature 没打开造成的假象。

第六类是 blocking mutex 的 owner handoff。

原来的 `RawMutex::unlock()` 会在唤醒 waiter 之前直接把 `owner_id` 写成那个 waiter 的 tid。这在单核或低竞争下看起来没问题，但 SMP 压力下会留下一个危险中间态：owner 已经指向某个任务，可这个任务还没有真正从 `lock()` 返回、也没有拿到 guard。v27 的 panic 说明这个中间态可以在用户 page fault 的 address-space lock 路径上表现成“当前线程自重入”。现在的实验修正是更保守的 unlock：先 `owner_id = 0`，再 `notify_one`，让被唤醒任务通过正常 CAS 重新抢锁。v28 已经越过 `quote` 失败点，这是目前最强的证据。

后面 846 秒的长跑还说明了另一个同步语义：这个 mutex 用 task id 做 owner 校验，所以 guard 不能是 Send；否则一个任务拿到的 guard 有可能在另一个任务上下文释放，owner 检查就会变成“idle 在释放 rustc 任务的锁”。因此把 `GuardSend` 改成 `GuardNoSend` 是和 owner-id 设计匹配的内核修正。

第七类是 usercopy 的上下文边界。

`access_user_memory()` 本质上依赖当前任务是 StarryOS user thread；否则没有正确的用户地址空间和 fault 处理上下文。v32 的第一层 panic 说明有些 VFS/syscall helper 可以在非 thread context 下碰到用户指针。现在的修正是先检查 context，不满足就返回 access error，并且 page fault path 如果发现自己已经持有同一个 address-space lock，就直接 fail fault，避免在 kernel usercopy 里重入锁。

同时零长度 usercopy 直接 no-op。这个和 syscall 语义一致，也避免 cleanup/idle 路径里出现“len=0 但仍然要求 user thread context”的假阳性。

第八类是日志噪声和反馈链路本身。

现在 full M6 中反复出现 `riscv_hwprobe` 未实现，这不是 Cargo 正确性 blocker，因为 Rust 会 fallback，但它会把串口日志打得很碎。这个可以作为一个小的 RISC-V ABI 兼容 PR 候选：实现保守版 `riscv_hwprobe`，测试直接 syscall 258 的正常 keys、未知 key、非法 flags 和 bad pointer。还有一个 `database or disk is full`，现在已经通过 guest `df` 证明不是 16G rootfs 满了，而是 Cargo global-cache last-use 数据库写入失败；它当前是非致命兼容性信号，不先讲成 OS bug。

## 9. QEMU 风险

这里必须主动说明：RISC-V QEMU TCG 的 `thread=multi` 有 LR/SC reservation 正确性风险。

所以我把结论分成两类：

- `thread=single`：正确性 baseline。
- `thread=multi`：速度潜力实验。

最终不能只拿 `thread=multi` 的通过结果当 correctness 证明。

## 10. 下一步

接下来按四块继续推进：

1. 以 `SMP=8 + jobs=1` 已完成的 pass2 selfbuild 和 boot smoke 作为多核产物 baseline，
   后续只改变 cargo 并行度，避免每次同时改变 kernel、rootfs 和 workload。
2. 如果出现明确 kernel panic/trap 或可复现用户态异常，就按 OS 功能拆成 PR：根因、最小修复、test-suite、CI/本地验证。
3. 如果 2 小时以上没有新的阶段信号，就不继续盲等，先缩短反馈：更小 cargo target、更清晰 heartbeat/当前 crate、或者重放单个失败阶段。
4. 先用小 workload 和 subset 把 `jobs=2/4/8` 的问题缩短到分钟级，再回到 full M6；`thread=multi` 只作为速度潜力实验，不作为 correctness 证明。
5. 找到具体 OS bug 就直接按 PR 标准推进：根因、内核最小修复、test-suite、CI 和本地验证；找不到具体 bug 时先补日志，不把猜测写成结论。

## 11. 收尾

一句话总结：

单核 guest self-build 已经跑通；8-HART StarryOS guest 也已经完成最终 pass2，产出 StarryOS kernel，并且这个 guest-built kernel 能再次以 8-HART 启动到 userland。多核线同时看到小 workload 加速，jobs=2 subset 通过，jobs>1 full 压力把问题收敛到内核调度、迁移和 mutex handoff 上。过程中对内核做的关键改动是：用户态抢占点补上了，用户任务迁移先保持安全亲和性，run queue 有了负载信号，早期 starry-kernel lib 构建也能直接覆盖 SMP 调度代码，blocking mutex 的 owner handoff 也有了更稳的修正方向。

讲给老师时，我会强调这些不是脚本修补，而是 SMP 下调度、迁移和同步语义的改进。脚本和日志只是为了证明这些内核改动是可复现、可验证的。
