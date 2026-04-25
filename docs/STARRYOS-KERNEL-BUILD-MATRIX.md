# StarryOS 内核：双架构编译、路径与「自举」说明

本文对应需求：**(1) 正常环境编 riscv + x86 两颗内核；(2) 用它们得到「新一轮」内核；(3) 列出路径；(4) 如何对比差异**。

---

## 1. 正常编译环境：一次编两颗（riscv64 + x86_64）

**推荐**：在 **`auto-os/starry`** 镜像里执行（与 `Dockerfile` / `reproduce-in-container.sh` 一致），保证 **`riscv64-linux-musl-cc`** 等工具可用，`lwext4_rust` 的 C 部分能通过 CMake。

```bash
cd /path/to/Auto-OS
docker run --rm --platform linux/arm64 \
  -v "$PWD:/work" -w /work \
  auto-os/starry \
  bash scripts/build-dual-kernels.sh
```

可选：**`cargo clean -p starryos` 后再各编一遍**（得到第二组 ELF，文件名带 `after-clean`）：

```bash
docker run --rm --platform linux/arm64 \
  -v "$PWD:/work" -w /work \
  auto-os/starry \
  bash scripts/build-dual-kernels.sh --second-pass
```

若 **第一遍已在同一工作区编完**，只想做 **clean + 再编 + 归档**（不再重复 first）：

```bash
docker run --rm --platform linux/arm64 --network host \
  -v "$PWD:/work" -w /work \
  auto-os/starry \
  bash scripts/build-dual-kernels.sh --second-pass-only
```

脚本结束时会将本次 **`MANIFEST-*.txt` 复制为 `docs/KERNEL-MANIFEST-latest.txt`**，便于 `git add` 留档。若 `cargo` 拉 GitHub git 依赖失败，可加 **`--network host`** 或设置 **`CARGO_NET_GIT_FETCH_WITH_CLI=true`** 后重试。

封装脚本：[`scripts/build-dual-kernels.sh`](../scripts/build-dual-kernels.sh)。  
宿主机为 **macOS** 且未装可用的 **riscv musl 交叉 gcc** 时，单独跑 `scripts/build.sh ARCH=riscv64` 常会失败（`riscv64-linux-musl-cc: cannot execute binary file`），**请用上面 Docker 方式**。

---

## 2. 「用编好的内核再编新的自己的内核」在仓库里的真实含义

这里要分清两件事：

| 含义 | riscv64 | x86_64 |
|------|---------|--------|
| **A. 宿主（或容器内）再编一轮** | 同一源码树，执行 `cargo clean -p starryos` 后再 `scripts/build.sh`（`build-dual-kernels.sh --second-pass` 已封装） | 同上 |
| **B. 在 QEMU 访客里编 Starry 内核** | 有官方 heavy 路径：**[`scripts/demo-m6-selfbuild.sh`](../scripts/demo-m6-selfbuild.sh)**（需 `tests/selfhost/rootfs-selfbuild-riscv64.img`，日志 **`.guest-runs/riscv64-m6/results.txt`**，成功标记 `M6-SELFBUILD-*`） | **仓库内无一键等价脚本**；访客里完整 `cargo build` starry 需自备 x86 rootfs + 工具链并自行编排 |

说明：

- **M5**（[`scripts/demo-m5-rust.sh`](../scripts/demo-m5-rust.sh)）是在访客里编 **hello / 小 cargo 工程**，不是整颗内核。
- **M6** 才是「在 Starry 里对 **starry 内核源码** 做 cargo 构建/检查」的演示；仍与交互 shell 里 `ls` 等问题可能并存，以日志为准。

因此：**(2)** 若指 **「同一树再编一版 / clean 后再编」** → 用 **`build-dual-kernels.sh --second-pass`**。若指 **「必须由已在跑的 Starry 内核当环境去编出另一颗 starry」** → 当前仓库 **仅 riscv 有 M6 这条重路径**。

---

## 3. 内核路径（你应关心的文件）

### 3.1 Cargo 默认产物（每次 `scripts/build.sh` 成功后会更新）

| 架构 | 路径（相对 Auto-OS 根） |
|------|-------------------------|
| riscv64 | `tgoskits/target/riscv64gc-unknown-none-elf/release/starryos` |
| x86_64 | `tgoskits/target/x86_64-unknown-none/release/starryos` |

### 3.2 `build.sh` 额外拷贝的「按平台命名」ELF

| 架构 | 路径 |
|------|------|
| riscv64 | `tgoskits/os/StarryOS/starryos/starryos_riscv64-qemu-virt.elf` |
| x86_64 | `tgoskits/os/StarryOS/starryos/starryos_x86-pc.elf` |

（`starryos_<PLAT_NAME>.elf` 中的 `PLAT_NAME` 来自对应 axplat 的 `axconfig.toml`。）

### 3.3 `build-dual-kernels.sh` 归档目录（带时间戳，便于对比多轮）

目录：**`.guest-runs/kernels/`**

- 首轮：`starryos-riscv64-<UTC>-first.elf`、`starryos-x86_64-<UTC>-first.elf`
- 若 `--second-pass`：`…-after-clean.elf` 各一  
- 同目录下 **`MANIFEST-<UTC>.txt`**：记录 `sha256sum` 与当时 `git` 提交。

大 ELF 建议 **不要提交进 git**；需要时本地生成即可。

---

## 4. 测试 / 对比这些内核的差异

### 4.1 静态对比（宿主或容器内）

```bash
bash scripts/compare-starry-kernels.sh
# 或显式路径：
bash scripts/compare-starry-kernels.sh \
  tgoskits/target/riscv64gc-unknown-none-elf/release/starryos \
  tgoskits/target/x86_64-unknown-none/release/starryos \
  .guest-runs/kernels/starryos-riscv64-*-first.elf
```

会输出 **`file`**、**体积**、**SHA-256**、以及少量 **strings** 片段，用于确认 **架构字符串**、是否同一轮构建等。

### 4.2 运行时对比（QEMU）

- **冒烟 / 串口**：见 [STARRYOS-GUEST-SMOKE.md](STARRYOS-GUEST-SMOKE.md) 与 [`scripts/qemu-run-kernel.sh`](../scripts/qemu-run-kernel.sh)。  
- **riscv vs x86**：必须用 **各自架构的 rootfs**（`make ARCH=riscv64 rootfs` / `make ARCH=x86_64 rootfs`），**不可混盘**。  
- **日志差异**：启动后看 **`platform = …`**、`**arch = …**` 行；riscv 会先有 OpenSBI 段，x86 先有 SeaBIOS/固件风格输出。

### 4.3 「第二轮」与「第一轮」是否不同

优先看 **SHA-256**（`compare-starry-kernels.sh` 或 `MANIFEST`）。若源码与锁文件完全未变，`after-clean` 重编仍可能与首轮 **哈希相同**（可复现构建）；若你改过代码或依赖，哈希会变。

---

## 5. 相关脚本索引

| 脚本 | 作用 |
|------|------|
| [`scripts/build.sh`](../scripts/build.sh) | 单架构 `ARCH=riscv64\|x86_64` release 内核 |
| [`scripts/build-dual-kernels.sh`](../scripts/build-dual-kernels.sh) | 双架构 + 可选 `--second-pass` + 归档到 `.guest-runs/kernels/` |
| [`scripts/compare-starry-kernels.sh`](../scripts/compare-starry-kernels.sh) | 多 ELF 对比 |
| [`scripts/qemu-run-kernel.sh`](../scripts/qemu-run-kernel.sh) | QEMU 起机 |
| [`scripts/demo-m6-selfbuild.sh`](../scripts/demo-m6-selfbuild.sh) | riscv 访客内编内核（重） |

---

## 6. 离线 / 受限网络：`drivercraft/arm-scmi`

若容器内 `cargo` 无法从 GitHub `git fetch` **`arm-scmi`**，本仓库使用 **`tgoskits/vendor/arm-scmi`**（与 `Cargo.lock` 中 commit `9e9942d9…` 一致）并在 **[`tgoskits/Cargo.toml`](../tgoskits/Cargo.toml)** 中通过 **`[patch."https://github.com/drivercraft/arm-scmi"]`** 指向该目录。更新 vendored 源码时须与 `Cargo.lock` 中的 git 修订保持同步。

---

## 7. 与能力评估文档的关系

交互 shell、外部命令等限制见 [SELFHOST-STATUS-AND-IMPROVEMENTS.md](SELFHOST-STATUS-AND-IMPROVEMENTS.md)；**不影响**你在宿主或 Docker 里用 `scripts/build.sh` 产出上述 ELF。
