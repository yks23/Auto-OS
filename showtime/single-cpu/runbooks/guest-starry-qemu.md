# Guest Starry QEMU Runbook

## 目标

在 guest StarryOS 环境里启动 QEMU，再运行单 CPU `riscv64-qemu-virt` StarryOS binary。这个路径用于证明 StarryOS guest 内部具备运行 QEMU/TCG 的能力。

## 当前状态

已经完成 nested smoke：外层 StarryOS 能启动到 userland，并在 guest 内运行 riscv64 Linux 版 `qemu-system-riscv64`。内层 QEMU 已经带 256M smoke rootfs 启动到内层 StarryOS userland，并打印测试通过标记。

关键结果：

```text
===NESTED-QEMU-SMOKE-BEGIN===
outer StarryOS userland reached
kernel_under_test=/opt/nested/starryos-singlecpu.bin
inner_rootfs=/opt/nested/rootfs-smoke-riscv64.img
QEMU emulator version 11.0.0 (Debian 1:11.0.0+ds-2)
OpenSBI v1.8
arch = riscv64
platform = riscv64-qemu-virt
===GUEST_BUILD_PASS===
nested_qemu_rc=0
===NESTED-QEMU-INNER-BOOT-SEEN===
```

日志：

```text
../logs/boot-guest-qemu.log
```

环境处理记录：

- `apt-get install qemu-system-misc` 会触发 riscv64 chroot 里的 postinst/systemd 路径，曾经失败。
- 实际采用 `apt-get download` + `dpkg-deb -x` 离线展开 `qemu-system-riscv`、`opensbi`、`qemu-efi-riscv64`，避免 postinst。
- 内层 kernel、内层 smoke rootfs 和 nested 脚本都放在外层 rootfs 的 `/opt/nested/`。

## 预期输入

- guest StarryOS rootfs 中可用的 `qemu-system-riscv64`
- 单 CPU kernel binary:
  - `../binaries/riscv64-qemu-virt/starryos-singlecpu.bin`
- inner smoke rootfs:
  - `/opt/nested/rootfs-smoke-riscv64.img`
- rootfs image:
  - 记录在 `../../shared/rootfs/README.md`
- guest 内可写目录，用于放日志和临时镜像

## 已运行 smoke

脚本：

```text
../../shared/scripts/nested-qemu-smoke.sh
```

注入内容：

```text
/opt/run-tests.sh -> nested-qemu-smoke.sh
/opt/nested/starryos-singlecpu.bin
/opt/nested/rootfs-smoke-riscv64.img
/opt/guest-onecrate-inner.sh -> exec /opt/run-tests.sh
```

外层 QEMU 命令：

```sh
docker run --rm --privileged \
  -v "$PWD":/work -w /work \
  auto-os/starry:latest \
  bash -lc 'timeout 240 qemu-system-riscv64 \
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
    -drive id=disk0,if=none,format=raw,file=.guest-runs/showtime/rootfs-nested-qemu.img,file.locking=off,snapshot=on \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0 \
    > showtime/single-cpu/logs/boot-guest-qemu.log 2>&1'
```

## 预期命令模板

```sh
qemu-system-riscv64 \
  -machine virt \
  -nographic \
  -m 512M \
  -smp 1 \
  -kernel /path/in/guest/starryos-singlecpu.bin
```

## 仍需关注

- QEMU TCG 对 mmap、signal、thread、timerfd、futex 等 syscall 的需求。
- guest 文件系统和 block image 的读写语义。
- 内层 smoke rootfs 当前会提示 `Filesystem is in error state`，但本次最小 userland smoke 已通过；后续要换成干净 rootfs 复测。
- 内层 `/proc/sysrq-trigger` 写入会被拒绝，因此不要把 poweroff 路径作为 pass 条件。

## 成功信号

日志应保存到：

- `../logs/boot-guest-qemu.log`

成功标准：

- guest QEMU 正常启动内层 StarryOS。
- 内层 StarryOS 输出 banner 或测试 pass。
- 未出现 host guest StarryOS 的 kernel panic。

当前 smoke 已证明：外层 StarryOS userland、guest 内 QEMU binary/firmware、内层 virtio-blk rootfs、内层 StarryOS userland smoke 这四段链路都能跑通。

不要把 `m6-selfbuild-guest-pass.log` 当作这一步的替代品；它证明的是 guest 编译能力，不证明 guest 内 QEMU 启动能力。

## 备注

单 CPU guest QEMU 路径不需要真实并行，因此不涉及 RISC-V MTTCG cross-hart LR/SC 正确性问题。
