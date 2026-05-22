# Commands Reference

Commands here are references and templates. Only move a command into `shared/scripts/` after it has been verified.

## Check PR status

```sh
gh pr checks <PR> --repo rcore-os/tgoskits --json name,bucket,state,workflow,link,startedAt,completedAt
```

## M6 selfbuild baseline

Stable baseline keeps the guest build serial and uses QEMU single-threaded TCG:

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
  -netdev user,id=net0 \
  2>&1 | tee .guest-runs/riscv64-m6/results-full-smp1-j1-up-native-qemu-tmpfs-checkpoint-pass3-lld.txt
```

This run produced `===M6-SELFBUILD-PASS===`; the copied showtime log is `showtime/single-cpu/logs/m6-selfbuild-guest-pass.log`.

## M6 log checks

```sh
rg -a 'Finished `release`|M6-SELFBUILD-PASS|starryos pass2 finished|panic|trap|FAIL|Segmentation' showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
rg -a "Compiling" showtime/single-cpu/logs/m6-selfbuild-guest-pass.log | tail -10
rg -a "checkpoint|target.tar|file: command not found" showtime/single-cpu/logs/m6-selfbuild-guest-pass.log
shasum -a 256 showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.elf showtime/single-cpu/binaries/riscv64-qemu-virt/starryos-singlecpu.bin
```

When searching for backticks in zsh, use single quotes around the pattern.

## QEMU SMP correctness mode

```sh
qemu-system-riscv64 ... -smp 4 -accel tcg,thread=single
```

## QEMU SMP speed experiment mode

```sh
qemu-system-riscv64 ... -smp 4 -accel tcg,thread=multi
```

Use this only as speed experiment unless validated on real hardware/correct emulator.
