# StarryOS M6 Self-Build: QEMU TCG 下的完整编译路径

## 目标

在 QEMU TCG 模拟的 RISC-V StarryOS 访客内，用 Alpine musl rustc/cargo 完整编译
starry-kernel（lib）→ starryos（pass1）→ starryos（pass2），实现 OS 自我编译（self-hosting）。

## 难点与解决方案

### 1. Alpine rustc 的 libscudo.so 在 QEMU TCG 下崩溃

**现象**：rustc 早期阶段（def_span query）出现 ICE，或 Scudo assertion failure。

**根因**：Alpine rustc 链接 `libscudo.so`（Scudo 硬化分配器），其使用原子操作
（`__scudo_allocate` 等）在 QEMU TCG 的 LR/SC 模拟下产生竞态，导致内存损坏。

**解决**：将 `libscudo.so` 替换为指向 musl libc 的符号链接。
所有涉及 rootfs 挂载注入的脚本均已添加此修复：
```
rm -f /opt/alpine-rust/usr/lib/libscudo.so
ln -sf /lib/libc.musl-riscv64.so.1 /opt/alpine-rust/usr/lib/libscudo.so
```

### 2. rust-std 元数据哈希不匹配（`requires meta_sized lang_item`）

**现象**：cargo check/build 对 `riscv64gc-unknown-none-elf` 目标报错找不到核心 lang_item。

**根因**：Alpine 构建的 rustc 内部元数据哈希与官方预编译 `rust-std` 不一致，
即使两者基于同一 commit。`-Z build-std` 可绕过此问题。

**解决**：使用 `-Z build-std=core,alloc,compiler_builtins` 从 rust-src 源码构建
libcore/liballoc/compiler_builtins，完全绕过预编译 rust-std。

需配合：
- `RUSTC_BOOTSTRAP=1`：在 stable rustc 上启用 `-Z` 标志
- rust-src tarball 预注入 rootfs（`/opt/rust-src-for-rootfs.tar.gz`）
- 工作区裁剪（strip workspace）：重写 rust-src 的 Cargo.toml/Cargo.lock 避免依赖 crates.io

### 3. rustc 并行前端 ICE（vec_cache.rs:201）

**现象**：`-Z threads>0` 下 rustc 并行前端在 QEMU TCG 时序下触发 ICE。

**解决**：通过 rustc wrapper 注入 `-Z threads=0` 禁用并行前端。

### 4. ccwrap 链接器选择：clang vs gcc vs musl-gcc

**现象**：
- `/usr/bin/clang` 不存在于 rootfs（clang 未安装）
- `/usr/bin/gcc`（Debian glibc gcc）在 QEMU TCG 下 collect2 segfault

**解决**：ccwrap 使用 Alpine musl gcc：
```
exec /opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc "$@"
```
musl gcc 更轻量，在 QEMU TCG 下稳定运行。

### 5. 内核 init.sh 路径冲突

**现象**：内核内嵌 `init.sh` 优先 exec `guest-onecrate-inner.sh`（旧测试脚本），
跳过 `run-tests.sh` → `build-starry-kernel.sh` 路径。

**解决**：demo-m6-selfbuild.sh 注入时将 `guest-onecrate-inner.sh` 替换为
delegate 脚本，直接 exec `run-tests.sh`。

### 6. SMP 内核页面错误

**现象**：`CARGO_BUILD_JOBS=2` 时内核出现 Supervisor Page Fault。

**解决**：设置 `CARGO_BUILD_JOBS=1` 降低并发压力。根因可能是 StarryOS 内核在高并发
I/O 下的竞态条件，需后续内核调试。

## 性能数据

QEMU TCG（-smp 1 -m 5G），Alpine musl rustc 1.95.0，CARGO_BUILD_JOBS=1：

| 阶段 | 耗时 | 说明 |
|------|------|------|
| subset smoke | ~15s | cargo metadata/pkgid 离线检测 |
| compiler_builtins build script | ~60s | host 目标链接 |
| core (lib) | ~20min | -Z build-std，最大单 crate |
| alloc (lib) | ~5min | -Z build-std |
| workspace deps (30+ crates) | ~45min | syn, hashbrown, ax-errno 等 |
| **star-kernel lib 总计** | **>70min** | 超时前编译了 30+ crate |

完整 starryos build（3 pass）预计需要 3-6 小时。

## 优化反馈循环的建议

### 短期（脚本/流程层面）

1. **增量构建**：rootfs 上保留 `target/` 目录，利用 `M6_RESUME=1` 和
   `.m6-done-{kernel-lib,pass1,pass2}` 标记跳过已完成阶段。

2. **更小的超时**：默认 4200s 太长。开发时设 `M6_QEMU_TIMEOUT_SEC=600`（10min），
   快速验证前几个 crate 是否正常。

3. **subset 烟雾测试**：`demo-m6-selfbuild.sh --subset` 在 15s 内验证 cargo 离线解析，
   适合 CI gate。

4. **并行度调优**：`CARGO_BUILD_JOBS=1` 稳定但慢。可尝试 `CARGO_BUILD_JOBS=2` 配合
   `-smp 2` 和 `-accel tcg,thread=single`，观察是否仍稳定。

### 中期（内核层面）

5. **KVM 加速**：在有 RISC-V KVM 支持的硬件上，QEMU KVM 比 TCG 快 10-50x。
   当前流程已兼容 KVM（只需移除 `-accel tcg,thread=single`）。

6. **内核稳定性**：高并发下的 Page Fault 需内核侧修复。可添加 stress test
   （多进程 dd+ cargo）系统化复现。

### 长期（架构层面）

7. **cross-compilation 替代**：若自编译仅用于验证（非生产），可在宿主机
   cross-compile 后将产物注入 rootfs，大幅缩短反馈周期。

8. **自举验证（bootstrap trust）**：完整自编译的意义在于验证 OS 能编译自身。
   可考虑 nightly CI 跑 subset + kernel-lib（~30min），全量 build 仅 release 触发。
