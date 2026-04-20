#!/usr/bin/env bash
# StarryOS Self-Hosting Demo M2 (REAL):
# - 在 starry guest 内跑 cc1 → as → ld 真实编译 hello.c
# - 跑出我们刚刚编的二进制
#
# 前提：
#   1. bash scripts/integration-build.sh ARCH=riscv64    # build kernel
#   2. sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64  # 造 rootfs
set -e
WORK=/workspace/.guest-runs/riscv64-m2
sudo mkdir -p "$WORK"
sudo chown -R "$(id -u):$(id -g)" "$WORK"
ROOTFS=/workspace/tests/selfhost/rootfs-selfhost-riscv64.img
ELF=/workspace/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos
[[ -f "$ROOTFS" ]] || { echo "rootfs not found: $ROOTFS"; exit 1; }
[[ -f "$ELF" ]] || { echo "kernel not found: $ELF"; exit 1; }

echo "[+] inject demo into rootfs..."
sudo umount /tmp/rfsmnt 2>/dev/null || true
sudo mkdir -p /tmp/rfsmnt
sudo mount -o loop "$ROOTFS" /tmp/rfsmnt
sudo tee /tmp/rfsmnt/root/hello.c > /dev/null << 'EOF'
#include <stdio.h>
int main(int argc, char **argv) {
    printf("Hello from %s, compiled INSIDE StarryOS!\n", argv[0]);
    return 0;
}
EOF
sudo tee /tmp/rfsmnt/opt/run-tests.sh > /dev/null << 'DEMO'
#!/bin/sh
cd /root
LIBGCC=/usr/lib/gcc/riscv64-alpine-linux-musl/14.2.0/libgcc.a
echo "================================================================"
echo "  StarryOS Self-Hosting Demo M2 (REAL): cc1 + as + ld in guest"
echo "================================================================"
echo "[1/5] Source code (/root/hello.c):"
cat hello.c
echo ""
echo "[2/5] Run cc1 inside starry (49MB GCC binary):"
/usr/libexec/gcc/riscv64-alpine-linux-musl/14.2.0/cc1 -march=rv64gc -mabi=lp64d -quiet hello.c -o /tmp/hello.s
wc -l /tmp/hello.s
head -8 /tmp/hello.s
echo ""
echo "[3/5] Run GNU as inside starry:"
as -march=rv64gc -mabi=lp64d /tmp/hello.s -o /tmp/hello.o
ls -la /tmp/hello.o
echo ""
echo "[4/5] Run GNU ld inside starry (link with musl crt + libc.a + libgcc.a):"
ld -static /usr/lib/crt1.o /usr/lib/crti.o /tmp/hello.o /usr/lib/libc.a $LIBGCC /usr/lib/crtn.o -o /tmp/hello
ls -la /tmp/hello
echo ""
echo "[5/5] Run the binary we just COMPILED INSIDE STARRY:"
/tmp/hello /tmp/hello
echo "================================================================"
echo "===M2-REAL-PASS==="
DEMO
sudo chmod +x /tmp/rfsmnt/opt/run-tests.sh
sudo umount /tmp/rfsmnt
echo "[+] inject done"

KERNEL=$WORK/starry.bin
riscv64-linux-musl-objcopy -O binary "$ELF" "$KERNEL"
RESULT=$WORK/results.txt
rm -f "$RESULT"
sudo timeout 900 qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp 1 -m 1G \
    -kernel "$KERNEL" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file="$ROOTFS" \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    > "$RESULT" 2>&1 < /dev/null &
QEMU=$!
trap "sudo kill -9 $QEMU 2>/dev/null" EXIT
for i in $(seq 1 880); do
    sleep 1
    if grep -q "M2-REAL-PASS\|panic" "$RESULT" 2>/dev/null; then break; fi
done
sudo kill -9 $QEMU 2>/dev/null
echo ""
echo "=== M2-REAL demo done ==="
strings "$RESULT" | grep -E "STARRYOS|\[1/5\]|\[2/5\]|\[3/5\]|\[4/5\]|\[5/5\]|Hello from|hello\.s|hello\.o|hello[ ]|M2-REAL-PASS|panic" | tail -30
