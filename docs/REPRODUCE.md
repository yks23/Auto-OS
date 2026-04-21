# REPRODUCE — 从 `git clone` 到 StarryOS 自编译 M5 demo

本文档手把手把你从一台干净的 Linux 机器，带到 **在 StarryOS guest 里跑通 `cargo build` 并执行刚编出的 RISC-V Rust 二进制** 这个里程碑（M5）。

> **目标**：在 QEMU 里启动 starry kernel → 内部跑 `rustc 1.95` 编 hello world → 内部跑 `cargo --offline build --release` 编多文件项目 → 执行 cargo 产出的二进制 → 看到 `===M5-DEMO-PASS===`。
>
> 全流程在 host 上耗时（参考 Ubuntu 24.04 / x86_64 / 16C / 16G）：
> - 装依赖：5–8 min（已装可跳过）
> - 造 rootfs：3–5 min（含拉 Alpine edge 的 rust 包，~700 MB）
> - kernel build：30 s
> - guest M5 demo：1–2 min
> - **首次端到端**：约 10–15 min；**复跑**（rootfs 缓存）：约 1.5 min。

---

## 0. 你需要的机器

| 项目 | 最低 | 推荐 |
|---|---|---|
| OS | Ubuntu 22.04 / Debian 12（其他 Linux 自行装等价包） | Ubuntu 24.04 |
| 架构 | x86_64 host（要跨编 RISC-V guest） | x86_64 |
| RAM | 4 GB | ≥8 GB（QEMU guest 默认 2 GB） |
| 磁盘 | 10 GB 空闲（rust rootfs 大） | 20 GB |
| 权限 | `sudo`（要 chroot + mount loop + binfmt） | 同左 |
| 网络 | 能访问 GitHub / dl-cdn.alpinelinux.org | 同左 |

> **不能在 macOS / Windows 直接跑**：要 binfmt_misc + chroot 来跨架构装 Alpine rootfs。VM/容器里跑也 OK，只要能 `sudo mount -o loop` 和 `binfmt_misc`。

---

## 1. 拿代码

```bash
git clone https://github.com/yks23/Auto-OS.git
cd Auto-OS
git submodule update --init tgoskits      # tgoskits 是大的，~200 MB
```

如果你本来就有 `Auto-OS`，确认已切到含本文的分支（`cursor/final-...` 或 `main` 合并后）：

```bash
ls scripts/check-env.sh scripts/setup-env.sh scripts/reproduce-all.sh
# 三个脚本都在 = 分支正确
```

---

## 2. 装依赖

我们提供两条路：**自动**（推荐，幂等）和 **手动**（如果你怕 setup 改你机器）。

### 2.1 自动 — 一键装

```bash
sudo bash scripts/setup-env.sh
```

它会做：
- `apt-get install` build-essential / git / curl / xz-utils / e2fsprogs / qemu-system-misc / qemu-user-static / binfmt-support / python3 / pkg-config
- 注册 `qemu-riscv64` binfmt（让 host 能跨架构 chroot 进 RISC-V Alpine）
- 装 `rustup`（如果没装）+ default `nightly`
- 加 `riscv64gc-unknown-none-elf` target 和 `rust-src` / `llvm-tools-preview` 组件
- 拉 [arceos-org/setup-musl](https://github.com/arceos-org/setup-musl) 的 prebuilt `riscv64-linux-musl-cross` 解到 `/opt/riscv64-linux-musl-cross/`

> **重要**：如果你已经有 `~/.cargo/`、`/opt/` 下其他 toolchain，setup-env 不会动，只补缺。

### 2.2 手动 — 自己装

```bash
sudo apt-get install -y build-essential git curl tar xz-utils e2fsprogs \
    qemu-system-misc qemu-user-static binfmt-support python3 pkg-config

# rustup
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain nightly --profile minimal
. "$HOME/.cargo/env"

# 不需要手动 add target — tgoskits 自带 rust-toolchain.toml，cargo 会
# 在第一次 build 时自动 fetch nightly-2026-04-01 + 所有 targets / components。

# musl cross
sudo mkdir -p /opt
curl -fL https://github.com/arceos-org/setup-musl/releases/download/prebuilt/riscv64-linux-musl-cross.tgz \
    | sudo tar -C /opt -xz
echo 'export PATH=/opt/riscv64-linux-musl-cross/bin:$PATH' >> ~/.bashrc
export PATH=/opt/riscv64-linux-musl-cross/bin:$PATH

# binfmt（apt 装好之后通常已经注册；没的话手动）
sudo update-binfmts --enable qemu-riscv64
```

### 2.3 验证

```bash
bash scripts/check-env.sh
# 期待最后看到：
#   Summary: 32 PASS, 0 WARN, 0 FAIL
```

如果有 **FAIL**，按提示装；如果只是 **WARN**（多半是 rust component 还没 fetch），可以忽略——`cargo build` 第一次跑会自动补。

---

## 3. 一键复现（推荐）

```bash
bash scripts/reproduce-all.sh
```

干这些：
1. **环境检测**（`check-env.sh`）
2. **tgoskits submodule** 同步到 Auto-OS 锁定的 commit（已含 T1-T10 + F-α/β/γ/δ + M1.5）
3. **应用 F-ε** vfork/posix_spawn 修复（`patches/F-eps/`）到 tgoskits 工作树
4. **build kernel**（`scripts/build.sh ARCH=riscv64`，绕开 tgoskits 的旧 Makefile，直接 `cargo axplat info` + `ax-config-gen` + 两遍 `cargo build`）
5. **build rootfs**（`tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust`，跨 chroot 装 Alpine rust 1.95 + cargo 1.95 + musl 工具链，~700 MB）
6. **跑 M5 demo**（`scripts/demo-m5-rust.sh`：注入 hello.rs / hellocargo 到 rootfs → 启 QEMU → 串口监 `===M5-DEMO-PASS===`）

可选 flag：

```bash
bash scripts/reproduce-all.sh --skip-env       # 已确认环境，跳过 check
bash scripts/reproduce-all.sh --skip-rootfs    # 复用已有 rootfs (节省 3-5 min)
bash scripts/reproduce-all.sh --help
```

成功时 stdout 末尾长这样：

```
================================================================
  ✓ M5 DEMO PASSED
  guest cargo build produced & ran its own RISC-V rust binary
================================================================

Highlights from the guest serial log:
    rustc 1.95.0 (59807616e 2026-04-14) (Alpine Linux Rust 1.95.0-r0)
    cargo 1.95.0 (f2d3ce0bd 2026-03-21) (Alpine Linux Rust 1.95.0-r0)
    rustc -C opt-level=0 hello.rs (rustc spawns cc as linker):
    rustc exit=0
    Hello from rustc, compiled INSIDE StarryOS!
    1..=10 sum = 55
    Compiling hellocargo v0.1.0 (/root/hellocargo)
    Finished `release` profile [unoptimized] target(s) in 17.78s
    cargo-build exit=0
    Hello from cargo, INSIDE StarryOS!
    add_squares(3, 4) = 25  (expect 25)
    ===M5-DEMO-PASS===

Full log: /workspace/.guest-runs/riscv64-m5/results.txt
```

> ✅ 看到 "M5 DEMO PASSED" 就赢了。完整 guest serial log 在 `.guest-runs/riscv64-m5/results.txt`，~165 行 / 5.8 KB。

---

## 4. 分步复现（出错时 / 想懂细节）

如果 `reproduce-all.sh` 中途挂了，按下面的步骤手动来，每一步独立可重跑。

### 4.1 同步 submodule

```bash
git submodule update --init tgoskits
git -C tgoskits reset --hard "$(git ls-tree HEAD tgoskits | awk '{print $3}')"
git -C tgoskits clean -fd
```

> 这个 commit (`6b97deab` 当前) 已经包含 T1-T10、F-α、F-β、F-γ、F-δ、M1.5 全部之前轮次的 patches。

### 4.2 应用 F-ε（本轮新增的核心 fix）

```bash
( cd tgoskits && git apply ../patches/F-eps/*.patch )
```

如果说 patch 已 apply 过：

```bash
( cd tgoskits && git apply --check --reverse ../patches/F-eps/*.patch )    # 已 apply
# 或重置并重新 apply：
( cd tgoskits && git checkout -- . )
( cd tgoskits && git apply ../patches/F-eps/*.patch )
```

F-ε 是什么、为什么需要：见 [`patches/F-eps/README.md`](../patches/F-eps/README.md)。一句话：StarryOS 老的 `do_clone` 把 `CLONE_VFORK` 退化成 fork，`musl posix_spawn` / `cargo` / `rustc` 全跑不通；F-ε 实现真 vfork + 共享 aspace 的 execve detach + 同步 task ctx satp。

### 4.3 编 kernel

```bash
export PATH=/opt/riscv64-linux-musl-cross/bin:$PATH
bash scripts/build.sh ARCH=riscv64
```

产出：

```
tgoskits/target/riscv64gc-unknown-none-elf/release/starryos    # ELF, ~4 MB
```

> 第一次 build 会比较慢（~3-5 min），因为 cargo 要 fetch nightly toolchain + crates。重 build 走增量 ~30 s。
>
> 如果你要看 starry kernel 内部 trace：`AX_LOG=info bash scripts/build.sh ARCH=riscv64`，再跑 demo。

### 4.4 造 rust rootfs

```bash
sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust
```

产出：

```
tests/selfhost/rootfs-selfhost-rust-riscv64.img       # ~3.8 GB ext4 image
tests/selfhost/rootfs-selfhost-rust-riscv64.img.xz    # ~750 MB xz
```

> 这一步：跨 chroot 用 `qemu-riscv64-static` 跑 Alpine `apk add rust cargo`。
> 我们额外打开了 Alpine **edge** 仓库（`PROFILE=rust` 时），因为 v3.21 主仓在 riscv64 上**没有** rust 包。

如果 `apk fetch` 慢/挂，可重跑该命令——它会从中断处续。

### 4.5 跑 demo

```bash
bash scripts/demo-m5-rust.sh
```

它会：
- 把 hello.rs / hellocargo 项目注入到 rootfs `/root/`
- 把 demo 脚本写进 rootfs `/opt/run-tests.sh`（被 starry init 自动执行）
- 启 QEMU（`qemu-system-riscv64 -m 2G -smp 1 …`）
- 串口监 `===M5-DEMO-PASS===` 标记，最长等 1500 s
- 把 guest 日志写到 `.guest-runs/riscv64-m5/results.txt`

成功条件：`results.txt` 含 `===M5-DEMO-PASS===`，并且脚本 exit 0。

---

## 5. 看到了什么

成功的 `results.txt` 里关键几行：

```
rustc 1.95.0 (59807616e 2026-04-14) (Alpine Linux Rust 1.95.0-r0)
cargo 1.95.0 (f2d3ce0bd 2026-03-21) (Alpine Linux Rust 1.95.0-r0)

[1.2] rustc -C opt-level=0 hello.rs (rustc spawns cc as linker):
rustc exit=0
Hello from rustc, compiled INSIDE StarryOS!
1..=10 sum = 55

[2.2] cargo --offline build --release (cargo->rustc->cc->ld):
   Compiling hellocargo v0.1.0 (/root/hellocargo)
    Finished `release` profile [unoptimized] target(s) in 17.78s
cargo-build exit=0
[2.3] Run the cargo-built binary:
Hello from cargo, INSIDE StarryOS!
add_squares(3, 4) = 25  (expect 25)
===M5-DEMO-PASS===
```

逐行解读：

| 行 | 解读 |
|---|---|
| `rustc 1.95.0` | guest 内 starry 加载了 Alpine 的 rustc 二进制并跑通 `--version` |
| `rustc exit=0` | rustc 全链路（codegen → posix_spawn cc → posix_spawn ld）OK |
| `Hello from rustc, compiled INSIDE StarryOS!` | 我们在 starry 里跑了刚刚 starry 自己编出来的 RISC-V ELF |
| `1..=10 sum = 55` | rust std 的 `Vec::iter().sum()` 在 starry 上工作 |
| `Compiling hellocargo` | cargo driver 正在 spawn rustc 子进程 |
| `Finished release profile in N s` | cargo 全链路成功 |
| `add_squares(3, 4) = 25` | 多文件 cargo 项目 + 模块系统 + 链接 + 运行 全部 OK |

---

## 6. Troubleshooting

### `qemu-system-riscv64: Could not open '/dev/kvm'`
忽略 — 我们不用 KVM；`-bios default` + 软件模拟即可。

### `error: F-eps patch ... cannot apply`
你 tgoskits 里有别的本地修改，或者 submodule 指针被 reset 到了别的 commit。修：

```bash
cd tgoskits
git fetch origin
git reset --hard "$(cd .. && git ls-tree HEAD tgoskits | awk '{print $3}')"
git clean -fd
cd ..
( cd tgoskits && git apply patches/F-eps/*.patch )      # 注意路径
```

### M5 demo 超时（`results.txt` 没出现 PASS 标记）
- 看 `.guest-runs/riscv64-m5/results.txt` 里**最后**几行：
  - 卡在 `posix_spawn` / `clone` → 没把 F-ε 应用上，回到 4.2。
  - 卡在 `Compiling` 没动 → guest 内存不够，把 `scripts/demo-m5-rust.sh` 里的 `-m 2G` 调大。
  - 看到 `panic` → 复制内核 panic 文本和提交 issue。
- 看 host：`ps -ef | grep qemu` 看 QEMU 是不是还活着；卡死 + 占满 CPU 通常是内核 deadlock，应该被 F-ε / F-δ / F-α 修过，没修就是新 bug。

### `mkfs.ext4: command not found` 在 setup 时
`sudo apt-get install e2fsprogs` 然后再跑。

### `chroot: failed to run command '/sbin/apk': No such file or directory`
binfmt 没注册或 `qemu-riscv64-static` 没装。`sudo update-binfmts --enable qemu-riscv64`，或重跑 `setup-env.sh`。

### `permission denied` 在 reset submodule 时
你之前 `sudo` 跑过 build，`tgoskits/target/` 里有 root 拥有的文件。`sudo chown -R "$(id -u):$(id -g)" tgoskits/`。

---

## 7. 接下来能玩什么

- **看老的 M2/M3-equivalent demo**（C 工具链版本，用 Alpine GCC 14 在 starry 内编 hello.c + 多文件 calc）：
  ```bash
  sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64    # minimal profile
  bash scripts/demo-phase5.sh
  # 期待 ===PHASE5-DEMO-PASS===
  ```

- **跑 31 个 syscall acceptance test**（M1.5）：
  ```bash
  bash scripts/run-tests-in-guest.sh
  ```

- **改 starry kernel 重新 build + demo**：改 `tgoskits/os/StarryOS/kernel/...`，重跑：
  ```bash
  bash scripts/build.sh ARCH=riscv64
  bash scripts/demo-m5-rust.sh
  ```
  （不必 reapply F-ε，working tree 不被覆盖）

- **了解修了什么内核 bug**：见 [`patches/F-eps/README.md`](../patches/F-eps/README.md) 和 [`docs/DEMO.md`](DEMO.md)。

---

## 8. 文件参考

| 文件/目录 | 用途 |
|---|---|
| `scripts/check-env.sh` | 只读环境检测（FAIL / WARN / PASS） |
| `scripts/setup-env.sh` | 一键装齐依赖（需 sudo） |
| `scripts/reproduce-all.sh` | 一键端到端复现 |
| `scripts/build.sh` | 编 starry kernel（绕过 tgoskits Makefile bug） |
| `scripts/demo-m5-rust.sh` | M5 demo（rustc + cargo build in guest） |
| `scripts/demo-phase5.sh` | 老 demo（cc1 + as + ld 在 guest） |
| `tests/selfhost/build-selfhost-rootfs.sh` | 造 Alpine rootfs（minimal/rust profile） |
| `patches/F-eps/` | 本轮新增 vfork/posix_spawn 修复 |
| `patches/T1` … `patches/M1.5` | 之前轮次（已 squash 进 submodule） |
| `docs/DEMO.md` | M5 demo 详细技术说明 |
| `docs/M5-DEMO-output.txt` | 一次成功 run 的完整 guest serial log |
| `tgoskits/` | StarryOS 内核源（git submodule） |
| `.guest-runs/` | QEMU run 工作目录（每次 demo 写在这里） |
