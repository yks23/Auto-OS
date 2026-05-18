# Host Linux QEMU Runbook

## 目标

在 host Linux 环境下用 QEMU 启动单 CPU `riscv64-qemu-virt` StarryOS binary，作为最基础的可运行证明。

## 输入

已放入本目录的输入：

- kernel bin: `../binaries/riscv64-qemu-virt/starryos-singlecpu.bin`
- kernel elf: `../binaries/riscv64-qemu-virt/starryos-singlecpu.elf`
- rootfs image: 记录在 `../../shared/rootfs/README.md`
- QEMU version: 记录在 `../../shared/references/environment.md`

## 已完成构建记录

```text
source_commit=Auto-OS 970bc85a6f04e62a3e0da27cb2f45dee8fd8251f / TGOSKit a81a6a7660ff2820631c7fd3dfe6d291ac023e60
branch=Auto-OS starryos-m6-reproduce-guide / TGOSKit fix/starry-robust-futex-cleanup
build_mode=StarryOS guest self-build
output_binary=showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
binary_sha256=d5a8dfb2b181ec7cd44485228c41556a4d2bcadcba7910eff37c3008d51261a3
elf_sha256=0ae612a47d959e3ca13d45db3c291f5ec8c34a791a870babe8607e3c863b1245
log=showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
```

## 启动记录模板

单 CPU 启动必须使用 `-smp 1`。如果只是验证 kernel 能否进入 StarryOS banner，可以先用最小启动命令；如果需要用户态 rootfs，再追加 virtio block 参数。

```sh
qemu-system-riscv64 \
  -machine virt \
  -bios default \
  -nographic \
  -m 7G \
  -smp 1 \
  -accel tcg,thread=single \
  -kernel showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
```

带 rootfs 的模板：

```sh
qemu-system-riscv64 \
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
  -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.img,file.locking=off \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0
```

## 成功信号

至少需要满足其一：

- 看到 StarryOS banner 并进入 shell。
- 运行指定 smoke test 并输出 pass。
- 对于自动化测试，日志中出现明确成功 pattern。

日志应保存到：

- `../logs/boot-host-qemu.log`

## 待验证问题

- 新提取出来的 `starryos-singlecpu.bin` 已在 macOS host QEMU 上完成一次非交互 boot smoke，日志为 `../logs/boot-host-qemu.log`。
- 还可以补一条真正 host Linux 环境下的同命令复测，避免把 macOS host 结果直接等同为 Linux host 结果。
- 如果 host 是 macOS，本 runbook 仍以 Linux host 为目标；macOS 只作为开发机，不作为最终验收环境。
