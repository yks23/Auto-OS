# StarryOS 访客冒烟：内核「能用」的验证说明

本文描述在 **QEMU + virtio-blk + rootfs** 下，如何证明 **x86_64 / riscv64** 编出来的 StarryOS 能进到 shell，并执行 **`echo` + `ls /`**（BusyBox 用户态）。依据当前仓库脚本与镜像（`scripts/qemu-run-kernel.sh`、`scripts/verify-starry-guest-smoke.sh`、`auto-os/starry` Dockerfile）。

## 1. 结论范围（能证明什么）

| 断言 | 说明 |
|------|------|
| 能证明 | 内核可引导、块设备根可用、出现 **`root@starry`** shell；串口上 **`echo STARRY_GUEST_SMOKE_MARKER`** 有回显；**`ls /`** 输出中出现 **`bin` / `etc` / `proc` / `usr` / `sbin`** 等根目录名。 |
| 不能证明 | 任意复杂 workload、长期稳定性、与 [SELFHOST-STATUS-AND-IMPROVEMENTS.md](SELFHOST-STATUS-AND-IMPROVEMENTS.md) 中 **§2 能力边界** 所述场景无冲突。若冒烟失败且日志像「卡死、无子进程」，请对照该文档。 |

**自动化**：[`scripts/verify-starry-guest-smoke.sh`](../scripts/verify-starry-guest-smoke.sh) 通过 **TCP 串口**（默认 **`127.0.0.1:4444`**，可用环境变量 **`SERIAL_TCP_PORT`** 改）连进访客发命令（需 **`docker run --network host`** 或等价，以便宿主机/脚本访问该端口）。

**已在以下环境跑通（x86_64）**：`docker run --platform linux/arm64 --network host -v "$PWD:/work" -w /work auto-os/starry`，对挂载的仓库执行 `bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64`，退出码 **0**，串口捕获中可见 **Welcome to Starry OS**、marker 与根目录列表。

## 2. 前置条件

1. **仓库根目录**为工作目录（下文记为 `$ROOT`）。
2. **已构建内核 ELF**  
   - x86_64：`bash scripts/build.sh ARCH=x86_64` → `tgoskits/target/x86_64-unknown-none/release/starryos`  
   - riscv64：`bash scripts/build.sh ARCH=riscv64` → `tgoskits/target/riscv64gc-unknown-none-elf/release/starryos`
3. **rootfs 与架构一致**（raw ext4 镜像，`qemu-run-kernel.sh` 里作 `format=raw`）  
   - **x86_64**：在 `tgoskits/os/StarryOS` 执行 `make ARCH=x86_64 rootfs`，使用 `make/disk.img` 或同目录 `rootfs-x86_64.img`。  
   - **riscv64（推荐用于本冒烟）**：在同一目录执行 `make ARCH=riscv64 rootfs`，使用 **`rootfs-riscv64.img`**（脚本默认优先该文件），或最近一次 `make rootfs` 复制后的 **`make/disk.img`**（须确认是 riscv 盘，而不是刚做过 x86 的残留）。  
   - **不要用 M5 自托管盘做本测试的默认盘**：`tests/selfhost/rootfs-selfhost-rust-riscv64.img` 的 init 会跑 **M5 rustc demo**，串口被占满且可能在内核里 **panic**，自动化脚本等不到稳定 **`root@starry#`**。若必须用它，请自行改 init 或换盘后再跑冒烟。

4. **QEMU**：`qemu-system-x86_64` / `qemu-system-riscv64` 在 PATH 中（`auto-os/starry` 镜像已 apt 安装）。

5. **Python 3**：冒烟脚本用其读串口（镜像含 `python3`）。

## 3. 一键自动验证（推荐）

在仓库根目录：

```bash
# x86_64（默认 KERNEL/DISK 见脚本内注释）
bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64

# riscv64（需已存在 tgoskits/os/StarryOS/rootfs-riscv64.img 或正确的 make/disk.img）
bash scripts/verify-starry-guest-smoke.sh ARCH=riscv64

# 显式指定盘与内核
KERNEL=tgoskits/target/x86_64-unknown-none/release/starryos \
DISK=tgoskits/os/StarryOS/make/disk.img \
bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64
```

**Docker（与当前 reproduce 习惯一致）**：

```bash
docker run --rm --platform linux/arm64 --network host \
  -v "$PWD:/work" -w /work \
  auto-os/starry \
  bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64
```

**超时**：ARM 宿主上 **TCG 模拟 x86** 可能极慢。可调：

```bash
export QEMU_BOOT_SEC=600    # 等待 shell / 发命令前的上限（秒）
export QEMU_TOTAL_SEC=720    # Python 读串口总时长（秒）
bash scripts/verify-starry-guest-smoke.sh ARCH=x86_64
```

成功时标准输出有 **`PASS: shell + echo + ls /`**，并在日志里提示捕获文件路径（容器内多为 `/tmp/starry-smoke-cap.*`）。

**端口**：默认 **`127.0.0.1:4444`**，与 `SERIAL_MODE=tcp` 的 [`scripts/qemu-run-kernel.sh`](../scripts/qemu-run-kernel.sh) 一致。若报 **`Address already in use`**（上一实例 QEMU 未退出、或另开终端仍占 4444），换端口即可，**两处用同一变量**：

```bash
export SERIAL_TCP_PORT=4445
bash scripts/qemu-run-kernel.sh ARCH=riscv64 KERNEL=... DISK=...
# 或
SERIAL_TCP_PORT=4445 bash scripts/verify-starry-guest-smoke.sh ARCH=riscv64
```

`qemu-run-kernel.sh` 也支持参数 **`SERIAL_TCP_PORT=4445`**。

## 4. 手工验证（与自动化等价）

1. 启动（默认 TCP 串口，便于无 TTY 环境）：

```bash
bash scripts/qemu-run-kernel.sh \
  ARCH=x86_64 \
  KERNEL=tgoskits/target/x86_64-unknown-none/release/starryos \
  DISK=tgoskits/os/StarryOS/make/disk.img
```

2. 待终端出现 **`QEMU waiting for connection on ... 0.0.0.0:<端口>`** 后，另开一终端（默认端口 **4444**；若改过 `SERIAL_TCP_PORT`，这里用同一端口）：

```bash
nc 127.0.0.1 "${SERIAL_TCP_PORT:-4444}"
```

3. 在 `nc` 里应能看到启动日志，直到 **`root@starry:/root #`**（或等价提示符）。输入：

```sh
echo hello-starry
ls /
```

若 **`hello-starry`** 回显且 **`ls /`** 下列出 `bin`、`etc` 等，即与自动冒烟的判定一致。

**交互式 Docker 串口**：若使用 `SERIAL_MODE=stdio`，须 **`docker run -it`**，并阅读 `qemu-run-kernel.sh` 头部关于 **勿与旧版 `-nographic`+stdio 混用** 的说明；否则优先 **TCP + `nc`**。

## 5. 失败时快速排查

| 现象 | 处理 |
|------|------|
| `KERNEL not found` / `DISK not found` | 先执行 `scripts/build.sh` 与对应 `make ARCH=... rootfs`。 |
| `connect 127.0.0.1:4444` 失败 / `Address already in use` | 换 **`SERIAL_TCP_PORT`**（见上）；或结束占用端口的 QEMU；Docker 加 **`--network host`**；确认未误用 `SERIAL_MODE=stdio` 却仍去 `nc 4444`。 |
| 自动脚本 FAIL，串口尾里有 **M5 / rustc** | riscv 用了 M5 盘：换 **`rootfs-riscv64.img`** 或 Starry **`make/disk.img`（riscv）**。 |
| 长时间无输出 | TCG 慢：增大 `QEMU_BOOT_SEC` / `QEMU_TOTAL_SEC`；或换真机/amd64 宿主加速。 |
| 与 fork/exec 相关 | 见 [SELFHOST-STATUS-AND-IMPROVEMENTS.md](SELFHOST-STATUS-AND-IMPROVEMENTS.md)。 |

## 6. 与仓库其它文档的关系

- **构建与 reproduce**：[REPRODUCE.md](REPRODUCE.md)  
- **内核能力边界**：[SELFHOST-STATUS-AND-IMPROVEMENTS.md](SELFHOST-STATUS-AND-IMPROVEMENTS.md)  
- **QEMU 参数与 rootfs**：[`scripts/qemu-run-kernel.sh`](../scripts/qemu-run-kernel.sh) 注释、`tgoskits/os/StarryOS/README.md`
