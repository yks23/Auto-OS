# Guest-built Kernel A/B Comparison

## 目的

对比两份 `riscv64-qemu-virt` StarryOS kernel：

- A: 原本用于 M6 guest selfbuild 的 reference kernel。
- B: StarryOS guest 内 self-build 产出的 guest-built kernel。

两者使用同一个 rootfs、同一个 QEMU 配置、同一个 smoke 流程，只替换 `-kernel` 参数。

## 测试对象

| item | kernel | sha256 |
| --- | --- | --- |
| reference | `.guest-runs/riscv64-m6/starry-up1.bin` | `44848a88ca62e55c15aa5dca39bca5356508af3b7a2d3672dcee27230f907ece` |
| guest-built | `showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin` | `d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3` |

共同输入：

```text
rootfs=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img
qemu_smp=1
qemu_accel=tcg,thread=single
rootfs_mode=snapshot
container=auto-os/starry:latest
```

## 测例

当前 smoke 覆盖：

1. OpenSBI + StarryOS kernel boot。
2. 进入 StarryOS userland。
3. 挂载 virtio rootfs。
4. 执行 M6 selfbuild init hook。
5. 检查 rootfs 中已存在的 guest-built StarryOS ELF。
6. 打印 `===M6-SELFBUILD-PASS===`。
7. 日志中不得出现 `panic`、`trap`、`FATAL`、`error: could not compile`、`Segmentation`。

## 结果

| item | log | result | key line |
| --- | --- | --- | --- |
| reference | `showtime/single-cpu/logs/boot-compare-reference-host-linux-qemu.log` | PASS | line 287: `===M6-SELFBUILD-PASS===` |
| guest-built | `showtime/single-cpu/logs/boot-host-linux-docker-qemu-guest-built.log` | PASS | line 287: `===M6-SELFBUILD-PASS===` |

共同成功信号：

```text
arch = riscv64
platform = riscv64-qemu-virt
smp = 1
parallelism: mode=single-vcpu-single-thread nproc=1 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1
found /opt/tgoskits/.m6-work/target/riscv64gc-unknown-none-elf/release/starryos — build already complete
===M6-SELFBUILD-PASS===
```

失败模式检查：

```sh
rg -a -n "panic|trap|FATAL|error: could not compile|Segmentation" \
  showtime/single-cpu/logs/boot-compare-reference-host-linux-qemu.log \
  showtime/single-cpu/logs/boot-host-linux-docker-qemu-guest-built.log
```

结果：无匹配。

## 可粘贴命令

跑 reference kernel：

```sh
docker run --rm --privileged \
  -v "$PWD":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'timeout 180 qemu-system-riscv64 \
    -nographic \
    -machine virt \
    -bios default \
    -smp 1 \
    -m 7G \
    -accel tcg,thread=single \
    -kernel .guest-runs/riscv64-m6/starry-up1.bin \
    -cpu rv64 \
    -monitor none \
    -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img,file.locking=off,snapshot=on \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    > showtime/single-cpu/logs/boot-compare-reference-host-linux-qemu.log 2>&1'
```

跑 guest-built kernel：

```sh
docker run --rm --privileged \
  -v "$PWD":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'timeout 180 qemu-system-riscv64 \
    -nographic \
    -machine virt \
    -bios default \
    -smp 1 \
    -m 7G \
    -accel tcg,thread=single \
    -kernel showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin \
    -cpu rv64 \
    -monitor none \
    -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.extract-fsck.img,file.locking=off,snapshot=on \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    > showtime/single-cpu/logs/boot-host-linux-docker-qemu-guest-built.log 2>&1'
```

检查对比结果：

```sh
rg -a -n "Platform Name|arch =|platform =|smp =|parallelism:|found .*starryos|===M6-SELFBUILD|panic|trap|FATAL|error: could not compile|Segmentation" \
  showtime/single-cpu/logs/boot-compare-reference-host-linux-qemu.log \
  showtime/single-cpu/logs/boot-host-linux-docker-qemu-guest-built.log
```

## 结论

在相同 Linux QEMU 环境、相同 rootfs、相同启动参数下，reference kernel 与 guest-built kernel 都能启动 StarryOS userland，并完成同一个 M6 resume smoke。当前证据支持：

> guest self-build 产出的 StarryOS kernel 可运行，行为与原本正确编译的 reference kernel 在该 smoke 测例上保持一致。
