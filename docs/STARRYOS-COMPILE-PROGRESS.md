# StarryOS 编译推进过程记录

日期：2026-05-16

## 总览

本记录用于说明从基础 guest 运行，到 guest 内 cargo hello，再到 StarryOS kernel/lib 编译实验的推进路径。当前实验不是单次“大编译”直接开始，而是按层级逐步验证：

```text
StarryOS guest boot
  -> hello world / 基础用户态程序
  -> guest 内 rustc/cargo hello 小工程
  -> guest 内 build-std
  -> guest 内 StarryOS / ArceOS kernel crate
```

这种推进方式的目的，是把问题定位在明确层次：启动、文件系统、exec、Rust 工具链、cargo 调度、链接器、内核 crate 配置。

## 1. Docker 编排环境

外层 Docker 镜像是：

```text
auto-os/starry
base image: ubuntu:24.04
```

它负责 host 侧编排：

- 安装 QEMU system/user。
- 安装 Rust nightly、cargo helper、musl cross toolchain。
- 构建或填充 StarryOS guest rootfs。
- 启动 QEMU RISC-V。
- 收集串口日志、结果文件和 syscall 统计。

注意：Docker 的 Linux 是 Ubuntu 24.04；但 StarryOS guest 里用于 cargo 的工具链主要来自 Alpine musl Rust，放在：

```text
/opt/alpine-rust/usr/bin/cargo
/opt/alpine-rust/usr/bin/rustc
```

因此这里有两层 Linux 用户态来源：

- Docker 编排层：Ubuntu 24.04。
- Guest rootfs 工具链层：Debian rootfs + Alpine musl Rust 工具链。

## 2. Hello world / 基础 guest 路径

第一层目标是确认 StarryOS guest 可以启动、挂载 rootfs、进入用户态并运行简单程序。该阶段证明：

- OpenSBI 和 StarryOS kernel 可以正常启动。
- virtio-blk rootfs 能挂载为 ext4。
- init delegation 能进入 guest 脚本。
- execve / wait / exit_group 等基础用户态路径可用。

相关日志位置：

```text
.guest-runs/cargo-hello-build-final-20260514T111512Z/serial.txt
```

该日志显示 guest 启动、文件系统挂载、进入用户态脚本，并开始后续 cargo hello 实验。

## 3. Guest 内 cargo hello 小工程

第二层目标是确认 Rust 工具链不是只在 host 上可用，而是真的可以在 StarryOS guest 内运行。

本轮 hello 小工程入口：

```text
mode=cargo-hello
crate=/tmp/onecrate-hello
CARGO_HOME=/opt/tgoskits/m6-cargo-home
cargo=/opt/alpine-rust/usr/bin/cargo
rustc=/opt/alpine-rust/usr/bin/rustc
```

关键日志标记：

```text
===GUEST_ONECRATE_BEGIN mode=cargo-hello ...===
[onecrate] hello-bin crate=/tmp/onecrate-hello
[onecrate] hello linker: .../rust-lld
[onecrate] phase=hello-build cargo build --manifest-path /tmp/onecrate-hello/Cargo.toml --offline
Task(..., "rustc") exit with code: 0
Task(..., "cargo") exit with code: 0
===GUEST_ONECRATE_CHECK_RC 0===
===GUEST_ONECRATE_ELAPSED_S 10===
===GUEST_ONECRATE_END===
```

结论：

- StarryOS guest 内可以执行 cargo。
- cargo 可以 fork/exec rustc。
- rustc 可以完成 hello 小工程编译。
- 链接器选择为 rust-lld，避开了此前部分 gcc/ld 路径在 QEMU TCG 下的不稳定问题。
- 该 hello cargo 实验耗时约 10 秒。

日志尾部存在退出清理阶段的额外问题，但出现在 `===GUEST_ONECRATE_END===` 之后，不影响 cargo hello 编译结果判定。

## 4. StarryOS kernel/lib 编译实验

第三层目标是进入真实 StarryOS / ArceOS 内核编译链路。

最新长跑配置：

```text
log=/tmp/m6-full-run10.log
M6_QEMU_SMP=1
M6_QEMU_MEM=5G
CARGO_BUILD_JOBS=1
RAYON_NUM_THREADS=1
phase=starry-kernel-lib
```

这个阶段与 hello 小工程不同，它不再只是验证一个独立小 crate，而是尝试在 guest 内编译 StarryOS kernel/lib 相关 crate。

推进过程包括：

- guest 内启动 cargo。
- 使用 `-Z build-std=core,alloc,compiler_builtins` 构建 Rust 基础库。
- 进入 ArceOS/StarryOS 依赖 crate。
- 日志中可观察到 `ax-hal`、`ax-driver-*`、`ax-task` 等内核组件编译。

这说明编译已经从“Rust 工具链可运行”推进到“真实内核 crate 可被 cargo 调度和编译”的阶段。

## 5. 编译与链接链路

在 guest 内，cargo 是调度器，rustc 是实际编译器：

```text
cargo
  -> 解析 Cargo.toml / features / target
  -> 按依赖拓扑调用 rustc
  -> rustc 输出 .rmeta / .rlib / .o
  -> linker 合成最终 ELF
```

对 StarryOS kernel/lib 来说，前置阶段包括：

```text
core
alloc
compiler_builtins
```

随后进入内核 crate：

```text
ax-hal
ax-driver-*
ax-task
starry-kernel
starryos
```

等全部 crate 编译通过后，最终链接阶段会按 kernel linker script 合成内核 ELF，确定：

- 入口地址。
- `.text` / `.rodata` / `.data` / `.bss` 段布局。
- boot stack / task stack / percpu 等内核符号。
- 内核加载地址和运行时地址。

当前重点还在 kernel crate 编译推进；最终完整 kernel ELF 链接与 boot 验证是下一层目标。

## 6. 速度与反馈链路

StarryOS kernel/lib 长跑约为 5 小时量级。主要原因：

- QEMU TCG 是软件模拟 RISC-V 指令。
- 当前为稳定性使用单 vCPU：`M6_QEMU_SMP=1`。
- cargo/rustc 当前单 job：`CARGO_BUILD_JOBS=1`。
- Rust 编译产生大量小文件读写，集中压力在 rsext4/ext4 路径。
- 串口日志和 syscall stats 也会带来 I/O 开销。

已有反馈优化：

- preflight 检查 rootfs、脚本、工具链、cargo cache。
- host heartbeat 判断 QEMU 是否仍在运行。
- guest heartbeat 判断 guest 脚本是否仍在推进。
- syscall stats 判断 cargo/rustc 是否还有系统调用活动。
- 按 hello、onecrate、build-std、starry-kernel-lib 分层验证。
- 准备了 `codex/quiet-rsext4-m6-logs` 降日志分支，用于下一轮减少串口刷屏。

## 7. 当前结论

当前编译推进已完成以下阶段：

```text
StarryOS guest boot                          已完成
hello world / 基础用户态程序                  已完成
guest 内 cargo hello 小工程                   已完成
guest 内 Rust/cargo 工具链可运行              已确认
guest 内 build-std                            已推进
guest 内 StarryOS kernel/lib crate 编译        已进入
最终 kernel ELF 链接与 guest-built kernel 启动  下一阶段
```

一句话总结：

```text
实验已经从“StarryOS 能跑 hello”推进到“StarryOS guest 里可以运行 cargo/rustc，并开始编译真实 StarryOS 内核组件”。
```
