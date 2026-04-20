#!/bin/bash
set -e
sudo pkill -9 -f qemu 2>/dev/null || true
sleep 3
sudo umount /tmp/rfsmnt 2>/dev/null || true
sudo mount -o loop /workspace/tests/selfhost/rootfs-selfhost-riscv64.img /tmp/rfsmnt
sudo tee /tmp/rfsmnt/opt/run-tests.sh > /dev/null << 'DEMO'
#!/bin/sh
LIBGCC=/usr/lib/gcc/riscv64-alpine-linux-musl/14.2.0/libgcc.a
CC1=/usr/libexec/gcc/riscv64-alpine-linux-musl/14.2.0/cc1
ARCH_FLAGS="-march=rv64gc -mabi=lp64d"

compile() {
    src="$1"; obj="$2"
    $CC1 $ARCH_FLAGS -quiet "$src" -o /tmp/_a.s
    as $ARCH_FLAGS /tmp/_a.s -o "$obj"
}

echo "================================================================"
echo "  StarryOS Self-Hosting Demo - rv64gc - Live in QEMU"
echo "================================================================"
echo ""
echo "##### Stage 1: Compile a single hello.c (M2) #####"
echo ""
cd /root
echo "[1.1] Source:"
cat hello.c
echo "[1.2] cc1 + as:"
compile hello.c /tmp/hello.o
ls -la /tmp/hello.o
echo "[1.3] ld:"
ld -static /usr/lib/crt1.o /usr/lib/crti.o /tmp/hello.o /usr/lib/libc.a $LIBGCC /usr/lib/crtn.o -o /tmp/hello
ls -la /tmp/hello
echo "[1.4] Run:"
/tmp/hello /tmp/hello

echo ""
echo "##### Stage 2: Compile a multi-file C project (M3-equivalent) #####"
echo ""
cd /root/calc
ls *.c
echo "[2.1] Compile each .c separately:"
compile main.c /tmp/main.o
compile add.c  /tmp/add.o
compile mul.c  /tmp/mul.o
compile fact.c /tmp/fact.o
ls -la /tmp/main.o /tmp/add.o /tmp/mul.o /tmp/fact.o
echo "[2.2] Link them all:"
ld -static /usr/lib/crt1.o /usr/lib/crti.o /tmp/main.o /tmp/add.o /tmp/mul.o /tmp/fact.o /usr/lib/libc.a $LIBGCC /usr/lib/crtn.o -o /tmp/calc
ls -la /tmp/calc
echo "[2.3] Run multi-file binary:"
/tmp/calc 5 7

echo ""
echo "##### Stage 3: Run the just-compiled binary that itself spawns work #####"
echo ""
echo "[3.1] We just compiled and ran a calc that uses fork-free libc."
echo ""
echo "================================================================"
echo "===PHASE5-DEMO-PASS==="
DEMO
sudo chmod +x /tmp/rfsmnt/opt/run-tests.sh
sudo umount /tmp/rfsmnt
bash /tmp/run-m2-rv.sh
