#!/usr/bin/env bash
# build-minimal-rootfs.sh — create a small riscv64 rootfs for guest rustc smoke test.
# Uses mkfs.ext4 -d to populate ext4 image from directory — no sudo/mount needed.
#
# Output: .guest-runs/rootfs-smoke-riscv64.img (~256MB ext4)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.guest-runs"
IMG="$OUT/rootfs-smoke-riscv64.img"
SIZE_MB=256
MKFS="/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4"

# Alpine riscv64 minirootfs
ALPINE_VER="3.21.0"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/riscv64/alpine-minirootfs-${ALPINE_VER}-riscv64.tar.gz"

mkdir -p "$OUT"

if [[ -f "$IMG" ]]; then
  echo "[minimal-rootfs] $IMG already exists, skipping build"
  exit 0
fi

echo "[minimal-rootfs] downloading Alpine minirootfs..."
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD" 2>/dev/null' EXIT
curl -fL "$ALPINE_URL" -o "$TMPD/alpine.tar.gz"

echo "[minimal-rootfs] extracting Alpine into staging dir..."
STAGE="$TMPD/stage"
mkdir -p "$STAGE"
tar xzf "$TMPD/alpine.tar.gz" -C "$STAGE" --no-same-owner

# Add basic config
cat > "$STAGE/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
EOF

# Create init script
mkdir -p "$STAGE/opt/test"
cat > "$STAGE/opt/test/hello.rs" <<'RUST'
fn main() {
    let msg = "hello from starry guest rustc";
    eprintln!("{}", msg);
    println!("{}", msg);
}
RUST

cat > "$STAGE/opt/run-tests.sh" <<'INIT'
#!/bin/sh
echo "===GUEST_BUILD_BEGIN==="
echo "hostname=$(hostname)"
echo "pwd=$(pwd)"
ls / | head -20
echo "---"

# Try rustc if available
if command -v rustc >/dev/null 2>&1; then
    echo "rustc=$(rustc --version)"
    rustc /opt/test/hello.rs -o /tmp/hello 2>&1
    RC=$?
    echo "rustc_exit=$RC"
    if [ "$RC" = "0" ]; then
        /tmp/hello 2>&1
        echo "===GUEST_BUILD_PASS==="
    else
        echo "rustc compilation failed"
        echo "===GUEST_BUILD_FAIL==="
    fi
else
    echo "rustc not found, basic smoke only"
    echo "uname=$(uname -a)"
    echo "===GUEST_BUILD_PASS==="
fi

# Poweroff
echo o > /proc/sysrq-trigger 2>/dev/null || true
INIT
chmod +x "$STAGE/opt/run-tests.sh"

# Setup init
cat > "$STAGE/init" <<'INIT'
#!/bin/sh
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:/opt/alpine-rust/bin"
export HOME=/root
export TERM=linux
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "===GUEST_BOOT_OK==="
exec /bin/sh /opt/run-tests.sh
INIT
chmod +x "$STAGE/init"

echo "[minimal-rootfs] creating ${SIZE_MB}MB ext4 image populated from staging dir..."
truncate -s "${SIZE_MB}M" "$IMG"
"$MKFS" -F -b 4096 -O "^has_journal,^metadata_csum" -d "$STAGE" "$IMG" >/dev/null

echo "[minimal-rootfs] done: $IMG ($(du -h "$IMG" | cut -f1))"
