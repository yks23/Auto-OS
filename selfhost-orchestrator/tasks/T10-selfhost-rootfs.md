# T10：selfhost rootfs 镜像（含 musl-gcc / binutils / make）

## 你的角色：D2 (Resource & Build)

## 目标
- 工作仓：`https://github.com/yks23/Auto-OS`
- PR 目标：`yks23/Auto-OS` selfhost-dev
- 交付物：scripts/build-selfhost-rootfs.sh + docs/SELFHOST-ROOTFS.md + sentinel
- **不改任何内核代码**，纯 host 端镜像构建工作

## 背景

self-hosting 终极目标是 guest 内 `cargo build` StarryOS 自己。前提是 rootfs 里有 toolchain。当前 rootfs（从 Starry-OS/rootfs 20260214 拉的）只有 BusyBox。我们要造一个**含 musl-gcc + binutils + make** 的镜像，guest 内可以编 `hello.c`。

## 范围

### 镜像 1：minimal-toolchain（必须）
- 基于 Alpine musl rootfs（http://dl-cdn.alpinelinux.org/alpine/v3.21/releases/{x86_64,riscv64}/alpine-minirootfs-3.21.0-{arch}.tar.gz）
- `apk add` 装：`build-base`（含 gcc / musl-dev / binutils）+ `make` + `bash` + `coreutils` + `findutils` + `grep` + `sed` + `awk`
- 产出 ext4 image（`mkfs.ext4 -d`），约 200-400 MiB
- 命名：`tests/selfhost/rootfs-selfhost-{arch}.img`（或 GitHub release）

### 镜像 2：含 rust（推荐，T21 才需要）
- 在 minimal-toolchain 基础上加 `apk add rust cargo`
- 产出约 1-2 GiB
- 命名：`rootfs-selfhost-rust-{arch}.img`

## 实现

### `scripts/build-selfhost-rootfs.sh`

```sh
#!/usr/bin/env bash
# 用法：
#   scripts/build-selfhost-rootfs.sh ARCH=x86_64
#   scripts/build-selfhost-rootfs.sh ARCH=riscv64 PROFILE=rust
set -euo pipefail
ARCH=...
PROFILE=...   # minimal / rust

# 1. 下 alpine-minirootfs tar.gz
# 2. 解到临时目录
# 3. chroot + qemu-{arch}-static + apk add build-base make bash coreutils ...
# 4. （PROFILE=rust）apk add rust cargo
# 5. 加 starry init.sh hook
# 6. mkfs.ext4 -d <dir> rootfs-selfhost-${ARCH}.img <size>
# 7. xz -k 压缩
```

要点：
- 用 `qemu-{arch}-static` + binfmt_misc 做跨架构 chroot（host 是 x86_64）
- Alpine `apk` 默认走 dl-cdn.alpinelinux.org（cloud agent 能联网）
- ext4 镜像大小要计算好（含 toolchain ~300 MiB）

如果你判断 `qemu-{arch}-static` chroot 太复杂，**fallback**：
- 仅做 x86_64 的（host 同架构，不需要 binfmt）
- riscv64 标 SKIP，写 followup-T10b

### 测试 / 验证

写 `scripts/verify-selfhost-rootfs.sh`：
1. 挂 `rootfs-selfhost-x86_64.img` 到 host /mnt/check
2. `chroot /mnt/check /usr/bin/gcc --version` 看输出含 "gcc"
3. `chroot /mnt/check /usr/bin/make --version`
4. `chroot /mnt/check /usr/bin/ld --version`
5. （PROFILE=rust）`rustc --version` `cargo --version`

不需要在 starry guest 内跑（M2 才会做）。

### 文档

写 `docs/SELFHOST-ROOTFS.md`：
- 镜像怎么造
- 镜像怎么用：`scripts/run-tests-in-guest.sh ARCH=x86_64 ROOTFS=rootfs-selfhost-x86_64.img`
- 镜像里有什么（gcc/musl-libc/binutils 版本）
- 大小、SHA256

## 完成信号

写 `selfhost-orchestrator/done/T10.done`：

```json
{
  "task_id": "T10",
  "status": "PASS|PARTIAL|FAIL|BLOCKED",
  "auto_os_branch": "cursor/t10-selfhost-rootfs-7c9d",
  "auto_os_commits": [...],
  "scripts_added": ["scripts/build-selfhost-rootfs.sh", "scripts/verify-selfhost-rootfs.sh"],
  "docs_added": ["docs/SELFHOST-ROOTFS.md"],
  "x86_64_image_built": true|false,
  "x86_64_image_path": "...",
  "x86_64_image_size_mb": 0,
  "riscv64_image_built": true|false,
  "riscv64_image_path": "...",
  "verify_gcc_in_image": "PASS|FAIL",
  "verify_make_in_image": "PASS|FAIL",
  "blocked_by": [],
  "decisions_needed": []
}
```

镜像文件**不要 commit 到 git**（太大），写到 `tests/selfhost/rootfs-selfhost-*.img` 然后加 .gitignore，sentinel 里写 host 路径。后续上传到 GitHub release 是另一步。

## 硬约束

- 卡 2 小时写 BLOCKED sentinel
- 失败也写
- 镜像不入 git
- 不改任何内核代码（patches/T*）
- 镜像构建脚本必须可重放（重跑产出一样）
