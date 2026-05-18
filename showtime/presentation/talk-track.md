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
showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
```

关键成功行是：

```text
Finished `release` profile [optimized] target(s) in 132m 59s
===M6-SELFBUILD-PASS===
```

编译出来的产物也已经放进：

```text
showtime/single-cpu/binaries/riscv64-qemu-virt/
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
- guest-built: `showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin`。

判据也一致：进入 StarryOS userland，找到 rootfs 内已经完成的 StarryOS ELF，打印 `===M6-SELFBUILD-PASS===`，并且没有 `panic/trap/FATAL/error`。这个对照能说明 guest self-build 产物在当前 smoke 上和原本正确编译的 kernel 行为一致。

## 5. 本次额外发现的问题

编译本身是成功的，但在 host 侧读回 checkpoint tar 时发现了文件系统一致性问题。

现象是 `/opt/tgoskits/.m6-checkpoints/target.tar` 直接读回会失败，`debugfs/e2fsck` 显示 duplicate extent 和 multiply-claimed blocks。

我没有在原始 rootfs 上修，而是在复制出来的镜像上 fsck，然后把最终 ELF/bin 提取出来放到 showtime。

这说明两个结论要分开：

- cargo build 成功是真的。
- checkpoint 大文件写回/读回路径需要单独做一个文件系统 regression。

## 6. PR 线索

最近几个 PR 我也整理进了 `showtime/single-cpu/docs/bugfixes.md`：

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

M6 这条线现在有四组证据：

- v19：`SMP=4 + jobs=1` 的完整 selfbuild 跑了很久，越过 `thiserror`、`ax-task`、`ax-driver`，没有 guest panic；最后是 host 把 QEMU kill 掉，所以不能算 full PASS，但能证明内核已经撑住了很长一段真实 workload。
- v20：`SMP=4 + jobs=2` 的 subset smoke 通过，日志里有 `nproc=4 CARGO_BUILD_JOBS=2 RAYON_NUM_THREADS=2` 和 `===M6-SELFBUILD-SUBSET-PASS===`。
- v21：`SMP=4 + jobs=2` 的 full early-pressure 进入真实 cargo build，跑到 `syn v2.0.117`，没有 panic 或 SIGSEGV，但后续 heartbeat 消失并触发 stall detector。
- v22：早期 `starry-kernel` lib 阶段已经带 `--features smp` 编译，heartbeat 继续推进到 `syn v1.0.109` 后触发 `StoreFault`，这给了一个可以继续缩小的具体内核 fault。

这说明多核不是“没起来”，而是已经进入真正的内核实现问题：jobs=2 的 CPU-heavy 阶段会挑战 scheduler、公平性、heartbeat 响应，以及页表/内存访问路径。

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

## 9. QEMU 风险

这里必须主动说明：RISC-V QEMU TCG 的 `thread=multi` 有 LR/SC reservation 正确性风险。

所以我把结论分成两类：

- `thread=single`：正确性 baseline。
- `thread=multi`：速度潜力实验。

最终不能只拿 `thread=multi` 的通过结果当 correctness 证明。

## 10. 下一步

接下来按四块继续推进：

1. 先把 v22 的 `StoreFault` 缩小成可复现的 OS regression。
2. 把用户态 timer/yield、用户任务唤醒亲和性、jobs=2 heartbeat stall 整理成可复现的 OS regression。
3. 在 `thread=single` 下逐步放大到 `jobs=4`，重点看 futex、锁、调度和文件系统路径。
4. 在 `thread=multi` 下做 4 核/8 核速度实验，但只作为性能潜力，不作为最终 correctness 证明。

## 11. 收尾

一句话总结：

单核 guest self-build 已经跑通；多核线已经看到小 workload 加速，jobs=2 subset 通过，full jobs=2 把问题收敛到内核调度响应性和 StoreFault 上。过程中对内核做的关键改动是：用户态抢占点补上了，用户任务迁移先保持安全亲和性，run queue 有了负载信号，早期 starry-kernel lib 构建也能直接覆盖 SMP 调度代码。

讲给老师时，我会强调这些不是脚本修补，而是 SMP 下调度、迁移和同步语义的改进。脚本和日志只是为了证明这些内核改动是可复现、可验证的。
