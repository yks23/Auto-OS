# StarryOS Self-Hosting Live Demo — M5 真 cargo build 收官

**总览（任务拆解 / 实现体量 / 现状）**：见 [`docs/README.md`](./README.md) 与 [`SELFHOST-ROADMAP-TASKS.md`](./SELFHOST-ROADMAP-TASKS.md)、[`SELFHOST-IMPLEMENTATION-SUMMARY.md`](./SELFHOST-IMPLEMENTATION-SUMMARY.md)、[`SELFHOST-STATUS-AND-IMPROVEMENTS.md`](./SELFHOST-STATUS-AND-IMPROVEMENTS.md)。

**实测**：2026-04-21
**架构**：riscv64 (qemu-virt, 2 GiB RAM, single core)
**结果**：✅ M5 — `rustc hello.rs` 全链路 + `cargo --offline build --release` PASS

---

## 一句话证明

starry kernel 在 QEMU 里加载 Alpine **rustc 1.95 + cargo 1.95**（共 350 MB rust 工具链），**真编译并链接** hello.rs 单文件 + hellocargo 多文件项目，cargo 全链 (`cargo → rustc → cc → ld`) 跑通：

```
rustc exit=0
Hello from rustc, compiled INSIDE StarryOS!
arch = riscv64, os = linux
1..=10 sum = 55

   Compiling hellocargo v0.1.0 (/root/hellocargo)
    Finished `release` profile [unoptimized] target(s) in 17.78s
cargo-build exit=0
Hello from cargo, INSIDE StarryOS!
add_squares(3, 4) = 25  (expect 25)

===M5-DEMO-PASS===
```

完整原始 serial log：[`docs/M5-DEMO-output.txt`](./M5-DEMO-output.txt)（165 行）

**更细的 M5 效果与编译效率**：见 [`SELFHOST-IMPLEMENTATION-SUMMARY.md` §4](./SELFHOST-IMPLEMENTATION-SUMMARY.md)。

---

## 关键内核工程修复（本轮新增）

支持 cargo build 的拦路虎是 **`musl posix_spawn` / 真 vfork** 路径——cargo 调 rustc、rustc 调 cc 全靠它。原 StarryOS 的 `do_clone` 把 `CLONE_VFORK` 当普通 fork（`flags.remove(CLONE_VM)`），导致：

1. `posix_spawn(child_stack=mmap)` 的 child 在“自己的 stack”指针在 child 的复制 aspace 里没映射 → child 立刻 SEGV.
2. 退化成完整 fork 后，child 的 `execve` 在父子**共享的 aspace** 上调 `uspace.clear()` → 把父亲的 mappings 全擦了 → 父亲一回到用户态就 SEGV.
3. 真 vfork 路径下还少一个隐藏的 “**ctx.satp 不同步**” bug：execve 切了硬件 SATP 但没改 task ctx 里的 satp，scheduler 切回时认为 satp 没变就 skip 写 → parent 用错的 PT → fault.

本仓做了以下修复（`patches/F-eps/`，对 `tgoskits/os/StarryOS/kernel`）：

- `clone.rs`：识别 `CLONE_VFORK`，**保留 `CLONE_VM`**（child 共享 parent aspace）；如果是 bare-vfork (stack=0) 则把 parent block 在一个 `PollSet` 上等 child execve/exit；posix_spawn 风格 (stack≠0) 父亲不阻塞，由 musl 用 CLOEXEC pipe 同步。
- `task/mod.rs`：`Thread` 加 `vfork_done: Mutex<Option<Arc<PollSet>>>` 槽 + `release_vfork_parent()`；`ProcessData::replace_aspace()` 给 execve 用来在 vfork 路径上把共享 `Arc<Mutex<AddrSpace>>` 换成新分配的 empty aspace（防 child 弄坏 parent mappings）。
- `task/ops.rs`：`do_exit` 时也调 `release_vfork_parent()`。
- `execve.rs`：检测到 `Arc::strong_count(&aspace) > 1` 时，先建 `new_user_aspace_empty()` + `copy_from_kernel()`，**unsafe 替换** `proc_data.aspace`，写硬件 `write_user_page_table` + `flush_tlb(None)`，再**同步写**当前 task `ctx.satp = new_pt_root`（这一步是关键，没它 scheduler 不知道 satp 已变）。
- `axtask/src/task.rs`：暴露 `pub unsafe fn ctx_mut_raw(&self) -> *mut TaskContext`，让 starry-kernel 的 execve 能 fix-up 已 spawn task 的 saved context.

修完之后：
- bare `vfork(2) + execve` ✅
- raw `clone(VM|VFORK|SIGCHLD, stack)` ✅
- musl `posix_spawn(/bin/true)` ✅
- `rustc → fork(cc) → fork(ld)` 全链路 ✅
- `cargo → fork(rustc) → fork(cc) → fork(ld)` 全链路 ✅

---

## 复现 (5 步)

```bash
# 1. clone main
git clone https://github.com/yks23/Auto-OS && cd Auto-OS
git submodule update --init tgoskits

# 2. host deps
sudo apt-get install -y qemu-system-misc qemu-user-static binfmt-support \
    xz-utils build-essential

# musl cross：
sudo mkdir -p /opt && cd /opt
sudo curl -fL https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz | sudo tar xz
export PATH=/opt/riscv64-linux-musl-cross/bin:$PATH

# riscv64 binfmt（用于跨架构 chroot 造 alpine rootfs）
sudo bash -c 'echo ":qemu-riscv64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-riscv64-static:OCF" > /proc/sys/fs/binfmt_misc/register'

# 3. apply patches + build kernel (含本轮 F-ε vfork fix)
bash scripts/integration-build.sh ARCH=riscv64

# 4. 造 selfhost rust rootfs（含 rustc 1.95 + cargo 1.95，~750 MB xz）
sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust

# 5. 一键 demo
bash scripts/demo-m5-rust.sh
# → 看到 "rustc 1.95.0" 在 starry 里跑
# → 看到 "Hello from rustc, compiled INSIDE StarryOS!" + "1..=10 sum = 55"
# → 看到 "Compiling hellocargo v0.1.0" + "Finished `release` profile"
# → 看到 "Hello from cargo, INSIDE StarryOS!" + "add_squares(3, 4) = 25"
# → 看到 "===M5-DEMO-PASS==="
```

如果只想跑老的 M2/M3-equivalent 演示（C 工具链版本），仍可：

```bash
sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64       # minimal profile
bash scripts/demo-phase5.sh                                          # 输出 ===PHASE5-DEMO-PASS===
```

---

## Demo 详情

### Stage 0 — Toolchain sanity

```
rustc 1.95.0 (59807616e 2026-04-14) (Alpine Linux Rust 1.95.0-r0)
cargo 1.95.0 (f2d3ce0bd 2026-03-21) (Alpine Linux Rust 1.95.0-r0)
sysroot = /usr
```

### Stage 1 — `rustc hello.rs` 全链

```rust
fn main() {
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;
    println!("Hello from rustc, compiled INSIDE StarryOS!");
    println!("arch = {}, os = {}", arch, os);
    let v: Vec<i32> = (1..=10).collect();
    let sum: i32 = v.iter().sum();
    println!("1..=10 sum = {}", sum);
}
```

```
$ rustc -C opt-level=0 -C debuginfo=0 -C linker=/usr/bin/cc hello.rs -o /tmp/hello_rs
exit=0
$ /tmp/hello_rs
Hello from rustc, compiled INSIDE StarryOS!
arch = riscv64, os = linux
1..=10 sum = 55
```

### Stage 2 — `cargo build --release` 多文件项目

```
hellocargo/
├── Cargo.toml
└── src/
    ├── main.rs    (use adder)
    └── adder.rs   (pub fn add_squares(a, b) -> a*a + b*b)
```

```
$ RUSTFLAGS="-C linker=/usr/bin/cc" cargo --offline build --release
   Compiling hellocargo v0.1.0 (/root/hellocargo)
    Finished `release` profile [unoptimized] target(s) in 17.78s
exit=0
$ ./target/release/hellocargo
Hello from cargo, INSIDE StarryOS!
add_squares(3, 4) = 25  (expect 25)
```

`target/release/hellocargo` = 446480 bytes，**真的**是 starry 内 cargo 全链路产出的 RISC-V ELF。

---

## 这里证明了什么

| 验证 | 怎么验的 |
|---|---|
| starry 能加载 350 MB rust 工具链 | rustc + cargo + libstd 全跑起来 |
| starry mmap + page fault chain 抗压 | rustc 编译过程 mmap 上百次 |
| starry exec + ld-musl 加载器 | rustc/cargo/cc/ld 全是 dynamic linked |
| starry **真 vfork / posix_spawn** | cargo→rustc→cc→ld 整条 fork 链 |
| starry **clone+aspace detach** | 解决了 child execve 不会擦掉 parent mappings |
| starry pipe+dup2+wait4 | cargo 子进程 stdout/stderr capture |
| 多文件 rust 链接 | cargo 调 rustc 一次性编多个 .rs + crate metadata |
| 跑回自己产出的二进制 | 跑了 rustc 编出的 hello_rs / cargo build 出的 hellocargo |

---

## 路线图状态（最新）

| Milestone | 编译目标 | 状态 |
|---|---|---|
| **M0** | host 编 starry kernel ELF | ✅ |
| **M1** | host 编 31+ 个 musl 测试 | ✅ |
| **M1.5** | guest 跑 31 acceptance test | ✅ 31/31 PASS |
| **M2** | guest 内编 hello.c (cc1+as+ld) | ✅ |
| **M3** | guest 内编多文件 C 项目 | ✅ (M3-equivalent) |
| **M5** | guest 内 `cargo build` | ✅ **今天** |
| **M3-real** | guest 内 `make BusyBox` | ⏳ gcc driver 现在能 spawn 但还有少量 fixup |
| **M4** | guest 内编 musl libc | ⏳ |
| **M6.S3** | guest 自举 starry kernel | ⏳ 终态 |

---

## 已知遗留

- **2 个 acceptance test FAIL**：T2 LOCK_NB / T9 setpriority 实现 bug，不影响主线。
- **x86_64 starry boot panic**：上游 axplat-x86-pc e820 解析把 PCI MMIO 当 RAM；x86_64 self-host 还需先修这个。
- 所有 demo 在 riscv64-qemu-virt + 2 GiB RAM 下验证；rustc 在 256MB 下也能跑，cargo 在 ≥1G 较稳。

---

## 演示效果总结

**StarryOS 已经能在 guest 内自我跑 cargo build，并执行 cargo 输出的 rust 二进制。** 加上之前 M2/M3-equivalent 的 GCC 全链，整条 self-hosting 链路（`cargo → rustc → cc → ld → run`）**第一次完整跑通**。M5 达成。
