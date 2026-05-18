# StarryOS 并发编译 StarryOS 测试方案

## 目标

验证的是“StarryOS guest 内并发编译 StarryOS”，也就是：

- guest 看到多 CPU：`getconf _NPROCESSORS_ONLN` 应该大于 1。
- cargo 真的并发：`CARGO_BUILD_JOBS>1`。
- rustc/rayon 工作线程真的并发：`RAYON_NUM_THREADS>1`。
- workload 是 StarryOS / tgoskits 自身，而不只是 hello world。
- 结果要能和单 CPU 串行 baseline 比较墙钟时间、通过标记和失败日志。

注意：QEMU RISC-V TCG 的 SMP 有两个模式，意义不同：

| 模式 | 示例 | 作用 | 能否作为正确性证明 |
| --- | --- | --- | --- |
| 串行 TCG，多 guest vCPU | `M6_QEMU_SMP=4 M6_TCG_THREAD=single` | guest 内能跑多 hart、多任务、cargo `-j4`，但宿主 TCG 串行执行 | 可以作为 QEMU TCG 下的 SMP 正确性证据 |
| 多线程 TCG，多 guest vCPU | `M6_QEMU_SMP=4 M6_TCG_THREAD=multi` | 宿主侧真正并行执行 TCG，可看速度信号 | 不能单独作为正确性证明，因为 RISC-V MTTCG LR/SC reservation 有已知风险 |

所以测试要分两条证据链：先证明 StarryOS SMP 下并发编译能正确完成，再单独看 MTTCG 是否有速度提升。

## 前置准备

从仓库根目录执行。建议所有长跑都使用独立 rootfs 副本，不要多个 QEMU 共用同一个 raw 镜像。

```sh
mkdir -p .guest-runs/showtime showtime/multi-cpu/logs

cp .guest-runs/rootfs-selfbuild-full-smp8.img \
  .guest-runs/showtime/rootfs-m6-serial.img

cp .guest-runs/rootfs-selfbuild-full-smp8.img \
  .guest-runs/showtime/rootfs-m6-smp4-correct.img

cp .guest-runs/rootfs-selfbuild-full-smp8.img \
  .guest-runs/showtime/rootfs-m6-smp4-mttcg.img
```

如果本地没有 `.guest-runs/rootfs-selfbuild-full-smp8.img`，先用已有 selfbuild rootfs 生成/下载流程补齐，再复制到这些测试副本。

## 阶段 0：最短冒烟

目的：先确认 rootfs、注入脚本、toolchain、离线 cargo registry 仍然能工作。

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-serial.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-serial-subset.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-serial-subset.progress.csv \
    M6_QEMU_SMP=1 M6_TCG_THREAD=single \
    CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=7200 \
    bash /work/scripts/demo-m6-selfbuild.sh --subset'
```

通过标准：

- 日志出现 `===M6-SELFBUILD-SUBSET-PASS===`。
- 日志中没有 `panic`、`trap`、`Segmentation`、`error: could not compile`。

## 阶段 1：单 CPU 串行 baseline

目的：拿到完整 StarryOS selfbuild 的串行时间，后面所有加速都和它比。

当前已有一条成功基线：`showtime/single-cpu/logs/m6-selfbuild-guest-pass.log`，guest 内最终 `cargo build --release` 报告 `132m 59s`，并打印 `===M6-SELFBUILD-PASS===`。

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-serial.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-serial-j1.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-serial-j1.progress.csv \
    M6_QEMU_SMP=1 M6_TCG_THREAD=single \
    CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=28800 \
    bash /work/scripts/demo-m6-selfbuild.sh'
```

记录：

- 总墙钟时间。
- `M6_RESULT` 日志路径。
- 是否出现 `===M6-SELFBUILD-PASS===` 或 `===M6-SELFBUILD-LIB-PASS===`。
- `Compiling` 行数和最后一个成功阶段。

## 阶段 2：SMP 正确性并发

目的：让 StarryOS guest 真正看到 4 个 CPU，并让 cargo/rayon 使用 4 路并发；但 QEMU TCG 用 `thread=single` 避开 RISC-V MTTCG LR/SC 风险。

先跑 subset：

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-smp4-correct.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-smp4-threadsingle-j4-subset.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-smp4-threadsingle-j4-subset.progress.csv \
    M6_QEMU_SMP=4 M6_TCG_THREAD=single \
    CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=7200 \
    bash /work/scripts/demo-m6-selfbuild.sh --subset'
```

subset 过了以后跑完整 selfbuild：

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-smp4-correct.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.progress.csv \
    M6_QEMU_SMP=4 M6_TCG_THREAD=single \
    CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=28800 \
    bash /work/scripts/demo-m6-selfbuild.sh'
```

这里预期不一定比单 CPU 快，因为宿主 TCG 被串行化了。它主要证明：

- StarryOS 多 hart 调度可支撑并发 cargo/rustc。
- futex、mutex、wait/wakeup、VFS、mmap、tmpfs、进程回收等路径没有被 `-j4` 打爆。
- guest 日志应该出现类似：

```text
parallelism: mode=multi-vcpu nproc=4 CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4
```

## 阶段 3：MTTCG 真并行测速

目的：看宿主侧真实并行 TCG 时，`-j4` 是否相对 `-j1` 有明显墙钟提升。

先跑 subset：

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-smp4-mttcg.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-smp4-mttcg-j4-subset.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-smp4-mttcg-j4-subset.progress.csv \
    M6_QEMU_SMP=4 M6_TCG_THREAD=multi \
    CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=7200 \
    bash /work/scripts/demo-m6-selfbuild.sh --subset'
```

再跑完整 selfbuild：

```sh
docker run --rm --privileged \
  -v "$(pwd)":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'ROOTFS=/work/.guest-runs/showtime/rootfs-m6-smp4-mttcg.img \
    M6_RESULT=/work/showtime/multi-cpu/logs/m6-smp4-mttcg-j4.log \
    M6_PROGRESS_LOG=/work/showtime/multi-cpu/logs/m6-smp4-mttcg-j4.progress.csv \
    M6_QEMU_SMP=4 M6_TCG_THREAD=multi \
    CARGO_BUILD_JOBS=4 RAYON_NUM_THREADS=4 \
    M6_RESUME=0 M6_QEMU_TIMEOUT_SEC=28800 \
    bash /work/scripts/demo-m6-selfbuild.sh'
```

这组如果比 baseline 快，只能说“速度实验有正信号”。要谨慎表述，不能把它当成最终 correctness 证明。

## 阶段 4：可选的 rustc 内部并发

默认脚本会让 rustc frontend 保持串行：`-Z threads=0`。这能把变量收敛到 cargo job 并发，适合作为第一轮。

等阶段 2、阶段 3 稳定后，再单独加一档：

```sh
M6_NO_SERIAL_RUSTC=1
```

这时测试的是“cargo 并发 + rustc 内部 frontend 并发”，压力更大，失败时不应该和前面的 cargo `-j4` 混在一起分析。

## 监控方式

长跑时开另一个终端看：

```sh
tail -f showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log
tail -f showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.progress.csv
```

高信号检查：

```sh
rg -a "parallelism:" showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log
rg -a "Compiling" showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log
rg -a "panic|trap|FATAL|error: could not compile|Segmentation" showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log
rg -a "===M6-SELFBUILD" showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log
```

## 结果表

每次跑完至少填这些字段：

| run | qemu smp | tcg thread | cargo jobs | rayon threads | result | wall time | log |
| --- | --- | --- | --- | --- | --- | --- | --- |
| serial-j1 | 1 | single | 1 | 1 | PASS | guest cargo `132m 59s` | `showtime/single-cpu/logs/m6-selfbuild-guest-pass.log` |
| smp4-correct-j4 | 4 | single | 4 | 4 | TODO | TODO | `showtime/multi-cpu/logs/m6-smp4-threadsingle-j4.log` |
| smp4-mttcg-j4 | 4 | multi | 4 | 4 | TODO | TODO | `showtime/multi-cpu/logs/m6-smp4-mttcg-j4.log` |

## 判断逻辑

1. 如果 `serial-j1` 不过，先不要讨论多核优化，先修 selfbuild 基线。
2. 如果 `serial-j1` 过但 `smp4-correct-j4` 不过，问题大概率在 StarryOS SMP 内核路径，例如 futex、mutex wakeup、调度、VFS/tmpfs、mmap、进程退出回收或页表/TLB。
3. 如果 `smp4-correct-j4` 过但 `smp4-mttcg-j4` 不过，优先怀疑 QEMU RISC-V MTTCG LR/SC 风险或被它放大的用户态原子问题。
4. 如果 `smp4-correct-j4` 过，`smp4-mttcg-j4` 也过且更快，可以把结论写成：StarryOS guest 并发 selfbuild 已有速度信号；正确性证据来自 `thread=single`，速度证据来自 `thread=multi`。

## PR 前需要拆出的测例

不要直接把“full selfbuild 过了”当成唯一测例。建议拆成：

- futex private/shared wake 测例：验证 `FUTEX_PRIVATE_FLAG` 不丢 wake，不错误共享 key。
- mutex unlock/wakeup 压力测例：多线程反复 lock/unlock，覆盖 waiter 被唤醒后看到 unlocked state。
- 多进程 cargo-like fork/exec/wait 测例：并发子进程退出、waitpid、文件创建删除。
- tmpfs/VFS 并发小文件测例：模拟 cargo target 高并发写入。
- M6 subset 测例：作为 PR 里的集成 smoke。

## 展示时的说法

推荐一句话总结：

> 我们把 StarryOS selfbuild 并发验证拆成三档：单 CPU 串行 baseline、`thread=single` 的 SMP 正确性、`thread=multi` 的真并行测速。这样可以避免把 QEMU MTTCG 的 RISC-V 原子风险误判成内核正确性问题，同时仍然能看多核是否真的带来速度收益。
