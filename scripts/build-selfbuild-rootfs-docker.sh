#!/usr/bin/env bash
# build-selfbuild-rootfs-docker.sh — build a riscv64 Debian rootfs with rustc.
#
# 1. Pulls riscv64/debian:sid-slim from Docker Hub
# 2. Exports filesystem
# 3. Uses qemu-riscv64-static chroot to install rustup + cargo
# 4. Converts to ext4 image with mkfs.ext4 -d
#
# Output: .guest-runs/rootfs-selfbuild-riscv64.img
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
OUT="$ROOT/.guest-runs"
IMG="$OUT/rootfs-selfbuild-riscv64.img"
TARBALL="$OUT/rootfs-riscv64-debian.tar"
MKFS="/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4"

mkdir -p "$OUT"

if [[ -f "$IMG" ]]; then
  echo "[selfbuild-rootfs] $IMG already exists, skipping build"
  exit 0
fi

echo "[selfbuild-rootfs] building riscv64 Debian rootfs with rustc..."

# Step 1: Pull and export riscv64 Debian rootfs
if [[ ! -f "$TARBALL" ]]; then
  echo "[1/4] pulling riscv64/debian:sid-slim..."
  docker pull --platform linux/riscv64 debian:sid-slim
  CTR=$(docker create --platform linux/riscv64 debian:sid-slim /bin/true)
  docker export "$CTR" > "$TARBALL"
  docker rm "$CTR" >/dev/null
  echo "  tarball: $(du -h "$TARBALL" | cut -f1)"
else
  echo "[1/4] tarball already exists, skipping pull"
fi

# Step 2: Install rustc via chroot inside Docker (skip if tarball exists)
TARBALL_RUST="$OUT/rootfs-riscv64-with-rust.tar"
if [[ -f "$TARBALL_RUST" ]]; then
  echo "[2/4] rust tarball already exists, skipping Docker chroot"
else
INNER="$(mktemp)"
cat > "$INNER" <<'INNEREOF'
set -euo pipefail
TARBALL="/output/rootfs-riscv64-debian.tar"
STAGE="/tmp/rootfs-stage"

rm -rf "$STAGE"
mkdir -p "$STAGE"
tar xf "$TARBALL" -C "$STAGE" --no-same-owner

# Set up chroot environment
cp /usr/bin/qemu-riscv64-static "$STAGE/usr/bin/"
chmod +x "$STAGE/usr/bin/qemu-riscv64-static"
mkdir -p "$STAGE/dev/proc"
cp -a /dev/null "$STAGE/dev/null" 2>/dev/null || mknod "$STAGE/dev/null" c 1 3
cp -a /dev/urandom "$STAGE/dev/urandom" 2>/dev/null || mknod "$STAGE/dev/urandom" c 1 9
cp -a /dev/random "$STAGE/dev/random" 2>/dev/null || mknod "$STAGE/dev/random" c 1 8
mount -t proc proc "$STAGE/proc" 2>/dev/null || true
echo "nameserver 8.8.8.8" > "$STAGE/etc/resolv.conf"

echo "[2/4] installing packages via apt (with retries)..."
chroot "$STAGE" /usr/bin/qemu-riscv64-static /bin/bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get clean 2>/dev/null
apt-get update 2>&1 | tail -3
# Upgrade base packages first to avoid version conflicts in sid
apt-get upgrade -y 2>&1 | tail -3
# Install in groups with retry (network can be flaky under qemu)
for i in 1 2 3; do
    apt-get install -y --fix-missing ca-certificates wget && break
    echo \"retry ca-certificates attempt \$i\"
    apt-get update -qq
done
for i in 1 2 3; do
    apt-get install -y --fix-missing gcc libc6-dev lld && break
    echo \"retry gcc attempt \$i\"
    apt-get update -qq
    apt-get --fix-broken install -y 2>&1 | tail -3
done
echo apt_done
which gcc wget cc ld.lld || true
" 2>&1 | tail -12

echo "[3/4] downloading and installing rustup..."
RUSTUP_URL="https://static.rust-lang.org/rustup/dist/riscv64gc-unknown-linux-gnu/rustup-init"
# Download on host (amd64) then copy into chroot
curl -fL "$RUSTUP_URL" -o "$STAGE/tmp/rustup-init"
chmod +x "$STAGE/tmp/rustup-init"

chroot "$STAGE" /usr/bin/qemu-riscv64-static /bin/bash -c "
export HOME=/root
export PATH=/usr/local/bin:/usr/bin:/bin
export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo
/tmp/rustup-init -y --default-toolchain nightly-2026-04-27 --profile minimal 2>&1 | tail -10
rm -f /tmp/rustup-init
echo rustup_done
" 2>&1 | tail -15

ls -la "$STAGE/root/.cargo/bin/rustc" "$STAGE/root/.cargo/bin/cargo"

# Clean up
umount "$STAGE/proc" 2>/dev/null || true
rm -f "$STAGE/usr/bin/qemu-riscv64-static"
rm -rf "$STAGE/var/cache/apt" "$STAGE/var/lib/apt/lists"

# Re-tarball
cd "$STAGE"
tar cf /output/rootfs-riscv64-with-rust.tar .
cd /
rm -rf "$STAGE"

echo "tarball with rustc created"
ls -lh /output/rootfs-riscv64-with-rust.tar
INNEREOF

echo "[2/4] installing rustc via Docker chroot (this takes 5-10 min)..."
docker run --rm \
  --platform linux/amd64 \
  --device /dev/urandom:/dev/urandom \
  --device /dev/random:/dev/random \
  -v "$OUT:/output" \
  -v "$INNER:/tmp/inner.sh:ro" \
  auto-os/starry:latest \
  bash /tmp/inner.sh

rm -f "$INNER"
fi  # end of Docker chroot skip

TARBALL_RUST="$OUT/rootfs-riscv64-with-rust.tar"
if [[ ! -f "$TARBALL_RUST" ]]; then
  echo "[selfbuild-rootfs] ✗ rust tarball not found"
  exit 1
fi

# Step 3: Add init scripts and build ext4
echo "[4/4] building ext4 image..."
STAGE="$OUT/rootfs-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
tar xf "$TARBALL_RUST" -C "$STAGE" --no-same-owner --exclude="./dev/*"

# Test files
mkdir -p "$STAGE/opt/test"
cat > "$STAGE/opt/test/hello.rs" <<'RUST'
fn main() {
    let msg = "hello from starry guest rustc";
    eprintln!("{}", msg);
    println!("{}", msg);
}
RUST

mkdir -p "$STAGE/opt/test-crates/src"
cat > "$STAGE/opt/test-crates/Cargo.toml" <<'TOML'
[package]
name = "guest-test"
version = "0.1.0"
edition = "2021"
[[bin]]
name = "hello"
path = "src/hello.rs"
TOML
cp "$STAGE/opt/test/hello.rs" "$STAGE/opt/test-crates/src/hello.rs"

# Guest onecrate script — kernel init.sh execs this directly via bash
# (bypasses the "cat: not found" issue in the starry-shrc path)
cat > "$STAGE/opt/guest-onecrate-inner.sh" <<'ONECRATE'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.cargo/bin"
export HOME=/root
export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo

echo "===GUEST_BUILD_BEGIN==="
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
echo "rustc=$(rustc --version 2>/dev/null || echo not-found)"
echo "cargo=$(cargo --version 2>/dev/null || echo not-found)"
echo "gcc=$(gcc --version 2>/dev/null | head -1 || echo not-found)"
echo "ld.lld=$(ld.lld --version 2>/dev/null | head -1 || echo not-found)"
echo "---"

# Find the crt startup files that gcc would normally link
CRTDIR="/usr/lib/riscv64-linux-gnu"
GCCDIR="/usr/lib/gcc/riscv64-linux-gnu/15"

# Cargo config: use ld.lld with --entry=_start to fix e_entry=0
mkdir -p /root/.cargo
cat > /root/.cargo/config.toml <<'CARGO_CFG'
[target.riscv64gc-unknown-linux-gnu]
linker = "ld.lld"
rustflags = ["-C", "target-feature=+crt-static", "-C", "linker-flavor=ld.lld", "-C", "link-arg=-L/usr/lib/riscv64-linux-gnu", "-C", "link-arg=-L/lib/riscv64-linux-gnu", "-C", "link-arg=-L/usr/lib/gcc/riscv64-linux-gnu/15", "-C", "link-arg=-z", "-C", "link-arg=muldefs", "-C", "link-arg=--entry=_start", "-C", "link-arg=/usr/lib/riscv64-linux-gnu/crt1.o", "-C", "link-arg=/usr/lib/riscv64-linux-gnu/crti.o", "-C", "link-arg=/usr/lib/gcc/riscv64-linux-gnu/15/crtbeginT.o", "-C", "link-arg=/usr/lib/gcc/riscv64-linux-gnu/15/crtend.o", "-C", "link-arg=/usr/lib/riscv64-linux-gnu/crtn.o"]
CARGO_CFG

# Test 1: rustc static compilation
echo "[test 1] rustc static hello.rs"
rustc -C target-feature=+crt-static \
      -C linker=ld.lld -C linker-flavor=ld.lld \
      -C link-arg=-L/usr/lib/riscv64-linux-gnu \
      -C link-arg=-L/lib/riscv64-linux-gnu \
      -C link-arg=-L/usr/lib/gcc/riscv64-linux-gnu/15 \
      -C link-arg=-z \
      -C link-arg=muldefs \
      -C link-arg=--entry=_start \
      -C link-arg=/usr/lib/riscv64-linux-gnu/crt1.o \
      -C link-arg=/usr/lib/riscv64-linux-gnu/crti.o \
      -C link-arg=/usr/lib/gcc/riscv64-linux-gnu/15/crtbeginT.o \
      -C link-arg=/usr/lib/gcc/riscv64-linux-gnu/15/crtend.o \
      -C link-arg=/usr/lib/riscv64-linux-gnu/crtn.o \
      /opt/test/hello.rs -o /tmp/hello 2>&1
RC=$?
echo "rustc_exit=$RC"
if [ "$RC" = "0" ]; then
    echo "===GUEST_RUSTC_PASS==="
    # Check file size (skip readelf to save memory)
    echo "binary size: $(ls -la /tmp/hello | awk '{print $5}') bytes"
    echo "---"
    /tmp/hello 2>&1
    HELLO_RC=$?
    echo "hello_run_rc=$HELLO_RC"
else
    echo "rustc failed (exit $RC)"
    echo "===GUEST_BUILD_FAIL==="
    echo o > /proc/sysrq-trigger 2>/dev/null || true
    exit 0
fi

# Test 2: cargo build (uses static config from .cargo/config.toml)
echo "[test 2] cargo build guest-test"
cd /opt/test-crates
cargo build --release 2>&1
RC=$?
echo "cargo_exit=$RC"
if [ "$RC" = "0" ]; then
    ./target/release/hello 2>&1 || true
    echo "===GUEST_CARGO_PASS==="
    echo "===GUEST_BUILD_PASS==="
else
    echo "cargo failed (exit $RC)"
    echo "===GUEST_BUILD_FAIL==="
fi

echo o > /proc/sysrq-trigger 2>/dev/null || true
ONECRATE
chmod +x "$STAGE/opt/guest-onecrate-inner.sh"

# Also keep the run-tests.sh for the starry-shrc path
cat > "$STAGE/opt/run-tests.sh" <<'SCRIPT'
#!/bin/sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.cargo/bin"
export HOME=/root
echo "===GUEST_BUILD_BEGIN==="
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
echo "rustc=$(rustc --version 2>/dev/null || echo not-found)"
echo "cargo=$(cargo --version 2>/dev/null || echo not-found)"
echo "gcc=$(gcc --version 2>/dev/null | head -1 || echo not-found)"
echo "---"

echo "[test 1] rustc /opt/test/hello.rs"
rustc /opt/test/hello.rs -o /tmp/hello 2>&1
RC=$?
echo "rustc_exit=$RC"
if [ "$RC" = "0" ]; then
    /tmp/hello 2>&1
    echo "===GUEST_RUSTC_PASS==="
else
    echo "rustc failed (exit $RC)"
    echo "===GUEST_BUILD_FAIL==="
    exit 0
fi

echo "[test 2] cargo build guest-test"
cd /opt/test-crates
cargo build --release 2>&1
RC=$?
echo "cargo_exit=$RC"
if [ "$RC" = "0" ]; then
    ./target/release/hello 2>&1
    echo "===GUEST_CARGO_PASS==="
else
    echo "cargo failed (exit $RC)"
    echo "===GUEST_BUILD_FAIL==="
    exit 0
fi

echo "===GUEST_BUILD_PASS==="
echo o > /proc/sysrq-trigger 2>/dev/null || true
SCRIPT
chmod +x "$STAGE/opt/run-tests.sh"

cat > "$STAGE/init" <<'INIT'
#!/bin/sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.cargo/bin"
export HOME=/root
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo "===GUEST_BOOT_OK==="
exec /bin/sh /opt/run-tests.sh
INIT
chmod +x "$STAGE/init"

truncate -s 2G "$IMG"
"$MKFS" -F -b 4096 -O "^has_journal,^metadata_csum" -d "$STAGE" "$IMG" >/dev/null 2>&1

rm -rf "$STAGE"
# Keep tarballs for faster re-runs of the ext4 stage only

echo "[selfbuild-rootfs] ✓ $IMG ($(du -h "$IMG" | cut -f1))"
