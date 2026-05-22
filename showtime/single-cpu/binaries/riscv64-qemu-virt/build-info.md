# Single CPU Guest-built StarryOS Artifact

## Result

- status: `PASS`
- produced by: StarryOS guest self-build, then extracted from the guest rootfs
- target: `riscv64-qemu-virt`
- CPU mode: `-smp 1`
- QEMU accel: `-accel tcg,thread=single`
- final cargo build time reported by guest: `132m 59s`
- source Auto-OS branch: `starryos-m6-reproduce-guide`
- source Auto-OS commit: `970bc85a6f04e62a3e0da27cb2f45dee8fd8251f`
- source TGOSKit branch: `fix/starry-robust-futex-cleanup`
- source TGOSKit commit: `a81a6a7660ff2820631c7fd3dfe6d291ac023e60`

## Files

```text
starryos-singlecpu.elf  4.5M
starryos-singlecpu.bin  2.4M
SHA256SUMS
```

The files were copied from:

```text
.guest-runs/riscv64-m6/starry-guest.elf
.guest-runs/riscv64-m6/starry-guest.bin
```

## Build Log

Full log:

```text
showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
```

Key success lines:

```text
Finished `release` profile [optimized] target(s) in 132m 59s
[4] starryos pass2 finished rc=0 (attempts=1)
===M6-SELFBUILD-PASS===
  starry kernel ELF was just produced INSIDE the starry guest!
```

## QEMU Command Used For The Guest Build

```sh
/opt/homebrew/bin/qemu-system-riscv64 \
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
  -drive id=disk0,if=none,format=raw,file=.guest-runs/rootfs-selfbuild-full-smp8.img,file.locking=off \
  -device virtio-net-pci,netdev=net0 \
  -netdev user,id=net0
```

## Extraction Note

The guest build itself completed successfully. Reading the checkpoint tarball back from Linux exposed a filesystem consistency issue: the original rootfs copy reported duplicate extents for `/opt/tgoskits/.m6-checkpoints/target.tar`. The extracted artifacts above were recovered by running `e2fsck -fy` on a copy of the rootfs only, then extracting the build output from that repaired copy.

This means the compile result is real, while the checkpoint write/readback path should be treated as a separate StarryOS filesystem follow-up.
