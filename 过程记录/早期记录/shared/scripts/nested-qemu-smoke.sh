#!/bin/bash
set +e

echo "===NESTED-QEMU-SMOKE-BEGIN==="
echo "outer StarryOS userland reached"
echo "PATH=$PATH"
echo "kernel_under_test=/opt/nested/starryos-singlecpu.bin"
echo "inner_rootfs=/opt/nested/rootfs-smoke-riscv64.img"

if ! command -v qemu-system-riscv64 >/dev/null 2>&1; then
  echo "qemu-system-riscv64: missing in guest rootfs"
  echo "===NESTED-QEMU-MISSING==="
  exit 42
fi

qemu-system-riscv64 --version | head -1

disk_args=()
if [ -f /opt/nested/rootfs-smoke-riscv64.img ]; then
  disk_args=(
    -device virtio-blk-pci,drive=disk0
    -drive id=disk0,if=none,format=raw,file=/opt/nested/rootfs-smoke-riscv64.img,file.locking=off
  )
else
  echo "inner rootfs: missing; booting kernel-only smoke"
fi

(timeout 60 qemu-system-riscv64 \
  -nographic \
  -machine virt \
  -bios default \
  -smp 1 \
  -m 256M \
  -kernel /opt/nested/starryos-singlecpu.bin \
  -monitor none \
  -serial mon:stdio \
  "${disk_args[@]}") 2>&1 | tee /tmp/nested-qemu.log

rc=${PIPESTATUS[0]}
echo "nested_qemu_rc=$rc"

if grep -q "arch = riscv64\|OpenSBI\|Starry" /tmp/nested-qemu.log; then
  echo "===NESTED-QEMU-INNER-BOOT-SEEN==="
else
  echo "===NESTED-QEMU-INNER-BOOT-NOT-SEEN==="
fi

exit "$rc"
