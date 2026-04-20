# Self-host Alpine rootfs 镜像（T10）

本任务交付的脚本与说明位于 **`tests/selfhost/`**（Auto-OS 仓内），不修改 `scripts/` / `docs/` 顶层目录，以便与 patches-only 工作流并存。

## 镜像里有什么

- 基底：[Alpine 3.21.0 minirootfs](http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/)（musl）。
- `PROFILE=minimal`：`apk add build-base make bash coreutils findutils grep sed gawk`  
  - `build-base` 含 **gcc**、**musl-dev**、**binutils** 等。
- `PROFILE=rust`：在 minimal 基础上再 `apk add rust cargo`（约 1–2 GiB 级，构建更久）。
- `/opt/selfhost-tests/`：占位目录；`patches/M1.5` 的 init.sh hook 会在存在 **`/opt/run-tests.sh`** 时自动执行——`scripts/run-tests-in-guest.sh` 会在挂载注入阶段写入该脚本，无需把镜像做得与 Starry 官方 BusyBox rootfs 一致。

## 如何构建

在 Auto-OS 仓根目录（需 root：mount / chroot / mkfs）：

```sh
sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=x86_64
sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=x86_64 PROFILE=rust
```

产出（默认被 `.gitignore` 忽略，勿提交大文件）：

| PROFILE | 文件 |
|---------|------|
| minimal | `tests/selfhost/rootfs-selfhost-x86_64.img`（及 `.xz`、`.sha256`） |
| rust    | `tests/selfhost/rootfs-selfhost-rust-x86_64.img`（及 `.xz`、`.sha256`） |

`riscv64`：在 **x86_64 host** 上需要 **`qemu-riscv64-static`** 与可用的 **`binfmt_misc`**（`update-binfmts` / 发行版 `qemu-user` 包）。当前许多 CI/agent 环境不具备，脚本会以退出码 **2** 失败并提示；后续可跟 **T10b** 专门打通 riscv64。

构建完成后可用：

```sh
sudo bash tests/selfhost/verify-selfhost-rootfs.sh tests/selfhost/rootfs-selfhost-x86_64.img
sudo bash tests/selfhost/verify-selfhost-rootfs.sh tests/selfhost/rootfs-selfhost-rust-x86_64.img --rust
```

## 如何在 QEMU / Starry 流程里使用

当前 `scripts/run-tests-in-guest.sh` **固定下载** Starry-OS 官方 BusyBox rootfs，尚未支持 `ROOTFS=...` 参数。要用本镜像跑 guest，请先将镜像路径传给 **`scripts/qemu-run-kernel.sh`** 的 `DISK=`（或把镜像拷为脚本期望的 `DISK` 路径），并照常执行 `integration-build`、`tests/selfhost` 的 `make` 与注入逻辑。待后续任务扩展 `run-tests-in-guest.sh` 后，可统一为：

`bash scripts/run-tests-in-guest.sh ARCH=x86_64` 且 `ROOTFS=tests/selfhost/rootfs-selfhost-x86_64.img`（规划中）。

## 体积与校验

- minimal-toolchain：通常约 **300–600 MiB** ext4（视缓存与 apk 版本浮动）。
- rust：通常 **1–2 GiB** 以上。
- 每次构建会生成 **`.sha256`**；请在本地对产物运行 `sha256sum` 记录，**不要**将 `.img` 提交到 git。发布到 GitHub Release 为后续步骤。

## 版本参考（以 Alpine 3.21 为准）

实际版本以镜像内为准，可在构建后 chroot 查看：

```sh
chroot /mnt /usr/bin/gcc --version
chroot /mnt /usr/bin/ld --version
chroot /mnt /usr/bin/make --version
```

典型输出包含 **gcc 14.x**、**GNU ld (GNU Binutils) 2.43.x**、**GNU Make 4.4.x**（随 apk 升级而变）。
