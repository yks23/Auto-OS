# 每个 Phase 的"小编译目标"（Compile Milestones）

每个 Phase 必须有一个**可在 QEMU 内现场验证的、产物能跑的编译产物**。
单看"PR 合并 / 测试通过"不够——必须能放出一个具体的"现在能编 X 了"。

## 总体阶梯

```
Host build only          guest 跑测试        guest 编小程序     guest 编大程序     guest 自举内核
        │                       │                   │                   │                   │
   Phase 0  ─────► Phase 1  ─────► Phase 2  ─────► Phase 3 / 4  ─────► Phase 5  ─────► Phase 6
   M0           M1                  M2 (S0)         M3 (S1)              M4 (S2)         M5/M6 (S3/S4)
```

## Milestone 表格（核心，逐 phase 一行）

| Phase | 编译目标 | 在哪里编 | 产物 | 验证命令 | 当前状态 |
|---|---|---|---|---|---|
| **0** | host 用 cargo 编出**空 patches** 下的 starry kernel ELF 双架构 | host | `target/{rv64,x86}/release/starryos`（4.1MB / 2.3MB） | `bash scripts/build.sh ARCH=riscv64 && bash scripts/build.sh ARCH=x86_64` | ✅ |
| **1** | host 用 cargo 编出 **T1-T5 全集** 下的 starry kernel ELF + 31 个 user-space test 双架构静态 musl | host | kernel ELF + 62 个 `out-{arch}/test_*` ELF | `bash scripts/integration-build.sh && cd tests/selfhost && make ARCH=riscv64 && make ARCH=x86_64` | ✅ |
| **1.5** | guest 内能 **跑**这些 test，**25/31 以上 PASS** | guest（kernel + BusyBox + 把 tests 拷进 rootfs） | qemu console 上看到 `[TEST] xxx PASS` ≥ 25 行 | `bash scripts/run-tests-in-guest.sh ARCH=riscv64` | ⏳ **下一步** |
| **2** | guest 内能编 **`hello.c` 静态 musl**，./hello 跑通 | guest（rootfs 必须有 musl-gcc） | `/tmp/hello` ELF (~10KB) | guest$ `cc /tmp/hello.c -o /tmp/hello && /tmp/hello` 输出 hello | 待做 |
| **3** | guest 内能编 **BusyBox 1.36** 完整 (~500 .o, ~1MB ELF) | guest（rootfs 含 musl-gcc + binutils + make） | `/tmp/busybox` ELF | `cd busybox-1.36 && make defconfig && make -j4 && ./busybox --list \| wc -l` ≥ 100 | 待做 |
| **4** | guest 内能编 **musl libc 自身** (~5MB .a) | guest | `/tmp/musl-1.2.5/lib/libc.a` | `cd musl-1.2.5 && ./configure --prefix=/tmp/musl && make -j4 && make install && file /tmp/musl/lib/libc.a` | 待做 |
| **5** | guest 内能 `cargo build --release` 一个 100 行 Rust 程序 | guest（rootfs 含 musl rustc + cargo） | `target/release/foo` ELF | `cargo new foo && cd foo && cargo build --release && ./target/release/foo` | 待做 |
| **6.S3** | guest 内能 build StarryOS **kernel ELF 自身** | guest | `target/.../starryos` (4.1MB / 2.3MB) | `bash scripts/build.sh ARCH=riscv64`（在 guest 内跑） | 待做 |
| **6.S4** | guest build 出的 ELF **字节** 与 host build 一致 | host 对比 | sha256 一致 | `sha256sum host.elf guest.elf` | stretch |

---

## 详细：每个 Milestone 的"小编译目标"具体长什么样

### M0 = Phase 0 出口：空 patches build kernel ELF
```bash
$ cd /workspace
$ bash scripts/build.sh ARCH=riscv64
[07:07:20] ✓ build OK: target/riscv64gc-unknown-none-elf/release/starryos
-rwxr-xr-x  3.9M starryos
$ bash scripts/build.sh ARCH=x86_64
[07:08:23] ✓ build OK: target/x86_64-unknown-none/release/starryos
-rwxr-xr-x  2.2M starryos
```
**衡量**：两个 ELF 都存在、`file` 看是 ELF、能被 `readelf -h` 解析。

### M1 = Phase 1 出口：T1-T5 全集 + tests 编译
```bash
$ bash scripts/integration-build.sh
[07:58:19] ✓ build OK: rv64 4.1M
[07:59:13] ✓ build OK: x86_64 2.3M
$ cd tests/selfhost && make ARCH=x86_64 && make ARCH=riscv64
$ ls out-x86_64 | wc -l
31
$ ls out-riscv64 | wc -l
31
```
**衡量**：62 个静态 ELF 都生成，每个都能 `file` 显示 "statically linked, not stripped"。

### M1.5 = Phase 1 真验证（**这一步我之前没写明**）
**目的**：把 31 个测试塞进 rootfs，QEMU 启动 kernel，看 BusyBox shell 跑测试结果。

```bash
$ bash scripts/run-tests-in-guest.sh ARCH=riscv64
... QEMU 启动 ...
[TEST] test_execve_basic PASS
[TEST] test_execve_multithread PASS
[TEST] test_flock_excl_block PASS
... 25 行以上 PASS / 6 行以下 FAIL ...
✅ Phase 1 验证通过
```
**衡量**：QEMU console 上 `[TEST] xxx PASS` 行数 ≥ 25（31 中至少 25 个通过；剩余允许 SKIP，不允许 FAIL）。**这是 Phase 1 的"真验收"**。

### M2 = Phase 2 出口：guest 内编 hello.c（S0）
**目的**：证明 guest 内的工具链能从 .c 源码做出能跑的二进制。

```bash
guest$ cat > /tmp/hello.c << 'EOF'
#include <stdio.h>
int main(){puts("self-host hello");}
EOF
guest$ cc /tmp/hello.c -o /tmp/hello && /tmp/hello
self-host hello
guest$ echo $?
0
```
**衡量**：exit 0 + stdout 含字符串。

### M3 = Phase 3 出口：guest 内编 BusyBox（S1）
**目的**：完整 C 项目（500 .c 文件、ld 链接 1MB ELF）能编。

```bash
guest$ tar xf /opt/sources/busybox-1.36.tar.gz -C /tmp
guest$ cd /tmp/busybox-1.36
guest$ make defconfig && make -j4
... 编译 5-10 分钟 ...
guest$ ./busybox --list | wc -l
353
```
**衡量**：`busybox --list` 输出 ≥ 100 个 applet；`./busybox echo hi` 输出 hi。

### M4 = Phase 4 出口：guest 内编 musl libc（S1.5）
**目的**：编译器深度自检（musl 是工具链自身的依赖，能编 musl 说明 ABI 完整）。

```bash
guest$ tar xf /opt/sources/musl-1.2.5.tar.gz -C /tmp
guest$ cd /tmp/musl-1.2.5
guest$ ./configure --prefix=/tmp/musl && make -j4 && make install
guest$ ls -lh /tmp/musl/lib/libc.a
-rw-r--r-- 5.2M libc.a
```
**衡量**：libc.a 存在 + 大小合理（4-6 MiB）。

### M5 = Phase 5 出口：guest 内 cargo build（S2）
```bash
guest$ rustc --version
rustc 1.83.0-musl
guest$ cargo new /tmp/foo && cd /tmp/foo
guest$ cargo build --release
guest$ ./target/release/foo
Hello, world!
```
**衡量**：rustc 与 cargo 都能 --version，`cargo build` 出 ELF 能跑。

### M6.S3 = Phase 6 真自举：guest 编 kernel ELF
**目的**：自举闭环。

```bash
guest$ cd /workspace/Auto-OS
guest$ bash scripts/integration-build.sh ARCH=x86_64
[xx:xx:xx] ✓ build OK: target/x86_64-unknown-none/release/starryos 2.3M
guest$ scp target/.../starryos host:/tmp/guest-built.elf
host$ qemu-system-x86_64 -kernel /tmp/guest-built.elf -nographic ... 
... 进入 BusyBox shell ...
starry:~# uname -a
Linux 10.0.0 #1 ...
```
**衡量**：guest 编出的 ELF 在 host QEMU 启动到 BusyBox shell。**这就是 self-hosting 闭环**。

### M6.S4 = stretch：reproducibility
```bash
host$ HOST_SHA=$(sha256sum host-built.elf | cut -d' ' -f1)
host$ GUEST_SHA=$(sha256sum guest-built.elf | cut -d' ' -f1)
host$ test "$HOST_SHA" = "$GUEST_SHA" && echo "BIT-EXACT REPRODUCIBLE"
```

---

## 当前进度

| Milestone | 状态 |
|---|---|
| M0 (Phase 0) | ✅ |
| M1 (Phase 1) | ✅ host build + tests 编译 |
| **M1.5 (Phase 1 真验证)** | **⏳ 下一步要做** — 把 31 测试塞 rootfs，QEMU run 看 PASS 数 |
| M2 (Phase 2 / S0) | 待做（依赖 selfhost rootfs T10） |
| M3 (Phase 3 / S1) | 待做 |
| M4 (Phase 4) | 待做 |
| M5 (Phase 5 / S2) | 待做 |
| M6 (Phase 6 / S3-S4) | 待做 |

## 路线变更

把 ROADMAP 里 Phase 1 的出口从"5 PR 合入 + ci-test 通过"**升级为 M1.5 = QEMU 内 31 测试 ≥25 PASS**。这才是 Phase 1 的真验收。

---

## 下一步立即做

我会立刻：
1. 写 `scripts/run-tests-in-guest.sh ARCH=...`：拉 starry rootfs，把 `tests/selfhost/out-<arch>/test_*` 拷进去，QEMU 启动，串口跑 BusyBox shell，自动顺序执行所有测试，grep `[TEST] xxx PASS|FAIL` 统计。
2. 跑 riscv64 + x86_64 各一次，记录"实测 X 个 PASS / Y 个 FAIL / Z 个 SKIP"。
3. **这就是 Phase 1 的真验收**，比 sanity-check 严格 100 倍——它会暴露每个 subagent 的 patch 在真实硬件下究竟工作不工作。

要我现在就去跑吗？预计 15-30 分钟（拉 rootfs + 双架构 QEMU 启动 + 跑测试）。
