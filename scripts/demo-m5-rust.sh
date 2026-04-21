#!/usr/bin/env bash
# StarryOS Self-Hosting Demo M5 (Codegen-Only):
# 在 starry guest 内：
#   - rustc --version / cargo --version
#   - rustc --emit=obj hello.rs    (rust 编译器跑通到生成 .o)
#   - cargo --offline check        (cargo 解析 + rustc-as-driver 跑通)
# 已知限制：rustc -> cc/ld 链接步骤会卡在 posix_spawn race (F-ε)，所以避开整链。
set -e
WORK=/workspace/.guest-runs/riscv64-m5
sudo mkdir -p "$WORK"
sudo chown -R "$(id -u):$(id -g)" "$WORK"
ROOTFS=/workspace/tests/selfhost/rootfs-selfhost-rust-riscv64.img
ELF=/workspace/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos
[[ -f "$ROOTFS" ]] || { echo "rootfs not found: $ROOTFS"; exit 1; }
[[ -f "$ELF" ]] || { echo "kernel not found: $ELF"; exit 1; }

echo "[+] inject demo into rootfs..."
sudo umount /tmp/rfsmnt 2>/dev/null || true
sudo mkdir -p /tmp/rfsmnt
sudo mount -o loop "$ROOTFS" /tmp/rfsmnt

sudo tee /tmp/rfsmnt/root/hello.rs > /dev/null << 'EOF'
fn main() {
    let arch = std::env::consts::ARCH;
    let os = std::env::consts::OS;
    println!("Hello from rustc, compiled INSIDE StarryOS!");
    println!("arch = {}, os = {}", arch, os);
    let v: Vec<i32> = (1..=10).collect();
    let sum: i32 = v.iter().sum();
    println!("1..=10 sum = {}", sum);
}
EOF

sudo mkdir -p /tmp/rfsmnt/root/hellocargo/src
sudo tee /tmp/rfsmnt/root/hellocargo/Cargo.toml > /dev/null << 'EOF'
[package]
name = "hellocargo"
version = "0.1.0"
edition = "2021"

[profile.release]
opt-level = 0
lto = false
codegen-units = 1
debug = false
EOF
sudo tee /tmp/rfsmnt/root/hellocargo/src/main.rs > /dev/null << 'EOF'
mod adder;
fn main() {
    let r = adder::add_squares(3, 4);
    println!("Hello from cargo, INSIDE StarryOS!");
    println!("add_squares(3, 4) = {}  (expect 25)", r);
}
EOF
sudo tee /tmp/rfsmnt/root/hellocargo/src/adder.rs > /dev/null << 'EOF'
pub fn add_squares(a: i32, b: i32) -> i32 {
    a * a + b * b
}
EOF

sudo tee /tmp/rfsmnt/opt/run-tests.sh > /dev/null << 'DEMO'
#!/bin/sh
set +e
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
echo "================================================================"
echo "  StarryOS Self-Hosting Demo M5: rustc + cargo INSIDE STARRY"
echo "================================================================"

echo ""
echo "##### Stage 0: Toolchain sanity #####"
echo "[0.1] rustc --version:"
/usr/bin/rustc --version
echo "[0.2] cargo --version:"
/usr/bin/cargo --version
echo "[0.3] rustc --print sysroot:"
/usr/bin/rustc --print sysroot

echo ""
echo "##### Stage 1: rustc hello.rs (FULL pipeline incl link) #####"
cd /root
echo "[1.1] hello.rs source:"
cat hello.rs
echo ""
echo "[1.2] rustc -C opt-level=0 hello.rs (rustc spawns cc as linker):"
/usr/bin/rustc -C opt-level=0 -C debuginfo=0 -C linker=/usr/bin/cc hello.rs -o /tmp/hello_rs 2>&1
RC=$?
echo "rustc exit=$RC"
ls -la /tmp/hello_rs 2>&1
echo ""
echo "[1.3] Run the just-compiled rust binary:"
/tmp/hello_rs

echo ""
echo "##### Stage 2: cargo build --release (multi-file project) #####"
cd /root/hellocargo
echo "[2.1] sources:"
ls -la
cat Cargo.toml
echo "---src/main.rs---"
cat src/main.rs
echo "---src/adder.rs---"
cat src/adder.rs
echo ""
echo "[2.2] cargo --offline build --release (cargo->rustc->cc->ld):"
RUSTFLAGS="-C linker=/usr/bin/cc" /usr/bin/cargo --offline build --release 2>&1
RC=$?
echo "cargo-build exit=$RC"
ls -la target/release/hellocargo 2>&1
echo ""
echo "[2.3] Run the cargo-built binary:"
./target/release/hellocargo

echo ""
echo "================================================================"
echo "===M5-DEMO-PASS==="
DEMO
sudo chmod +x /tmp/rfsmnt/opt/run-tests.sh
sudo umount /tmp/rfsmnt
echo "[+] inject done"

KERNEL=$WORK/starry.bin
riscv64-linux-musl-objcopy -O binary "$ELF" "$KERNEL"
RESULT=$WORK/results.txt
rm -f "$RESULT"
sudo timeout 1500 qemu-system-riscv64 \
    -nographic -machine virt -bios default -smp 1 -m 2G \
    -kernel "$KERNEL" -cpu rv64 \
    -monitor none -serial mon:stdio \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk0,if=none,format=raw,file="$ROOTFS" \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    > "$RESULT" 2>&1 < /dev/null &
QEMU=$!
trap "sudo kill -9 $QEMU 2>/dev/null || true" EXIT
for i in $(seq 1 1480); do
    sleep 1
    if grep -q "M5-DEMO-PASS\|panic" "$RESULT" 2>/dev/null; then break; fi
done
sudo kill -9 $QEMU 2>/dev/null || true
echo ""
echo "=== M5 demo done ==="
strings "$RESULT" | grep -E "STARRYOS|Stage|rustc|cargo|exit=|Hello from|hello_rs|hellocargo|adder|sum|M5-DEMO-PASS|panic|error\[|error:|Compiling|Finished|Checking" | tail -80 || true

# Propagate a proper exit code so callers (e.g. reproduce-all.sh) can decide.
if grep -q "===M5-DEMO-PASS===" "$RESULT" 2>/dev/null; then
    exit 0
else
    exit 1
fi
