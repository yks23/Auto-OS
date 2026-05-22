# Rootfs Notes

## M6 selfbuild rootfs

当前 M6/selfbuild 相关默认 rootfs：

```text
.guest-runs/rootfs-selfbuild-full-smp8.img
```

SHA256:

```text
0f4aa5f8a577921157218cd9b4047fad8e54d62cd66403831acdd25a7b8dd4cf  .guest-runs/rootfs-selfbuild-full-smp8.img
```

## 使用原则

- showtime 中不要直接改原始 rootfs，先复制到本次 run 的工作目录。
- 每次 run 记录 rootfs checksum。
- 如果向 rootfs 注入脚本、binary 或 symlink，需要写入对应日志。

## 已知 M6 约束

- guest cargo build 稳定路径仍建议：
  - `CARGO_BUILD_JOBS=1`
  - `RAYON_NUM_THREADS=1`
- bare-metal cargo build 常用：
  - `RUSTC_BOOTSTRAP=1`
  - `-Z build-std=core,alloc,compiler_builtins`
- Alpine toolchain 路径优先使用：
  - `riscv64-alpine-linux-musl-gcc`
  - `riscv64-alpine-linux-musl-g++`

## 本次 readback 注意事项

M6 guest self-build 已经成功产出 StarryOS kernel，但 checkpoint tar 的 host 读回暴露了 ext4 consistency 问题：

```text
/opt/tgoskits/.m6-checkpoints/target.tar
```

为避免修改原始证据，只在复制出来的镜像上运行过 `e2fsck -fy`：

```text
.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
```

这个副本只用于提取 showtime binary，不作为新的基线 rootfs。

## Nested QEMU rootfs

当前 nested QEMU smoke 使用外层 rootfs 副本：

```text
.guest-runs/showtime/rootfs-nested-qemu.img
```

SHA256:

```text
4bc7cd6c6a2454da148923724eb7408b85840782ac7c16ae33699e9076f01cae  .guest-runs/showtime/rootfs-nested-qemu.img
```

已注入内容：

```text
/usr/bin/qemu-system-riscv64
/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
/opt/run-tests.sh
/opt/nested/nested-qemu-smoke.sh
/opt/nested/starryos-singlecpu.bin
/opt/nested/rootfs-smoke-riscv64.img
```

验证日志：

```text
showtime/single-cpu/logs/boot-guest-qemu.log
```

结果：外层 StarryOS userland 成功运行 guest 内 `qemu-system-riscv64`，内层 StarryOS 启动到 userland 并打印 `===GUEST_BUILD_PASS===`。

## 待补

- 多 CPU benchmark rootfs checksum。
- 把 nested QEMU 的 rootfs 注入步骤整理成可重复脚本。
- 用干净 inner rootfs 复测，消除当前 smoke rootfs 的 `Filesystem is in error state` 提示。
