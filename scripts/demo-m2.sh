#!/bin/bash
set -e
ELF=/workspace/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos
DISK=/workspace/tests/selfhost/rootfs-selfhost-riscv64.img
WORK=/workspace/.guest-runs/riscv64-m2
sudo mkdir -p $WORK
sudo chown -R $(id -u):$(id -g) $WORK
KERNEL=$WORK/starry.bin
riscv64-linux-musl-objcopy -O binary "$ELF" "$KERNEL"
RESULT=$WORK/results.txt
rm -f "$RESULT"
sudo timeout 600 qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp 1 -m 128M \
    -kernel "$KERNEL" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file="$DISK" \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    > "$RESULT" 2>&1 < /dev/null &
QEMU=$!
trap "sudo kill -9 $QEMU 2>/dev/null" EXIT
for i in $(seq 1 580); do
    sleep 1
    if grep -q "M2-PASS\|panic\|unable to" "$RESULT" 2>/dev/null; then break; fi
done
sudo kill -9 $QEMU 2>/dev/null
echo "=== M2 done ==="
strings "$RESULT" | grep -E "M2|Hello|gcc \(GCC|GNU Make|panic|Welcome" | tail -30
