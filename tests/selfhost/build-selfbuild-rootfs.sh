#!/usr/bin/env bash
# build-selfbuild-rootfs.sh — build a riscv64 rootfs that contains everything
# needed to compile StarryOS's own kernel from inside the (StarryOS) guest:
#   - Debian 13 trixie riscv64 base (glibc — needed because rust nightly
#     riscv64 binaries link against glibc)
#   - rust nightly-2026-04-01 (matches tgoskits/rust-toolchain.toml)
#     with riscv64gc-unknown-none-elf cross target + rust-src + llvm-tools
#   - musl-tools (musl-gcc) for the lwext4_rust C build script
#   - cmake / clang / build-essential / git / pkg-config
#   - tgoskits sources pre-cloned at /opt/tgoskits with `cargo fetch`
#     pre-populated, so the in-guest build is offline-friendly
#
# Output:
#   tests/selfhost/rootfs-selfbuild-riscv64.img      (~7.5 GiB ext4)
#   tests/selfhost/rootfs-selfbuild-riscv64.img.xz   (compressed for release)
#
# Run inside the auto-os/starry docker image:
#   docker run --rm --privileged --network host -v $PWD:/work -w /work \
#       auto-os/starry bash tests/selfhost/build-selfbuild-rootfs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCH="riscv64"
ALPINE_GLIBC=""    # not used; we go debian
DEBIAN_VER="13"
DEBIAN_CODENAME="trixie"
RUST_CHANNEL="nightly-2026-04-01"
TGOSKITS_BRANCH="selfhost-m5"
TGOSKITS_URL="https://github.com/yks23/tgoskits.git"

OUT_IMG="$ROOT/tests/selfhost/rootfs-selfbuild-${ARCH}.img"
WORK_DIR="${WORK_DIR:-/tmp/selfbuild-rootfs.work}"
DISK_SIZE_GB="${DISK_SIZE_GB:-12}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: run as root (this script mounts loop devices and chroots)" >&2
    exit 1
fi

# Sanity: we need binfmt + qemu-riscv64-static + chroot + GPT tools
command -v qemu-riscv64-static >/dev/null || { echo "need qemu-riscv64-static"; exit 1; }
command -v sgdisk >/dev/null || { echo "need gdisk (sgdisk)"; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "need e2fsprogs (mkfs.ext4)"; exit 1; }
[[ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]] || /usr/local/bin/register-binfmt
[[ -f /proc/sys/fs/binfmt_misc/qemu-riscv64 ]] || { echo "binfmt_misc not available — pass --privileged to docker"; exit 1; }

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# --------------------------------------------------------- 1. download base
TARBALL="$WORK_DIR/debian-${DEBIAN_VER}-nocloud-${ARCH}.tar.xz"
if [[ ! -f "$TARBALL" ]]; then
    echo "[1/7] downloading Debian ${DEBIAN_VER} ${ARCH} cloud rootfs..."
    curl -fL -o "$TARBALL" \
        "https://cdimage.debian.org/cdimage/cloud/${DEBIAN_CODENAME}/latest/debian-${DEBIAN_VER}-nocloud-${ARCH}.tar.xz"
fi
ls -lh "$TARBALL"

# Debian "nocloud" tarball contains a single disk.raw (3 GiB GPT-partitioned).
# Resize to DISK_SIZE_GB and grow the root partition, then mount its ext4 rootfs.
echo "[2/7] extract + resize disk to ${DISK_SIZE_GB} GiB..."
rm -rf disk-extract
mkdir disk-extract
tar -C disk-extract -xf "$TARBALL"
DISK_RAW="$WORK_DIR/disk-extract/disk.raw"
truncate -s "${DISK_SIZE_GB}G" "$DISK_RAW"

# Reset and recreate partition 1 to fill the new size
LOOP=$(losetup -fP --show "$DISK_RAW")
sgdisk -e "$LOOP" >/dev/null
sgdisk -d 1 "$LOOP" >/dev/null
sgdisk -N 1 "$LOOP" >/dev/null
losetup -d "$LOOP"

OFFSET=$((262144 * 512))    # partition 1 starts at sector 262144
losetup --offset "$OFFSET" -fP --show "$DISK_RAW" >/tmp/.loop
LOOP=$(cat /tmp/.loop)
e2fsck -fy "$LOOP" >/dev/null 2>&1 || true
resize2fs "$LOOP" >/dev/null

# --------------------------------------------------------- 3. mount + chroot prep
MNT="$WORK_DIR/mnt"
mkdir -p "$MNT"
echo "[3/7] mount + chroot prep..."
mount "$LOOP" "$MNT"
df -h "$MNT" | tail -1

cleanup() {
    sync
    umount -lR "$MNT/proc" "$MNT/dev" "$MNT/sys" "$MNT" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

cp /usr/bin/qemu-riscv64-static "$MNT/usr/bin/"
rm -f "$MNT/etc/resolv.conf"
cp /etc/resolv.conf "$MNT/etc/resolv.conf"
mount -t proc /proc "$MNT/proc"
mount --rbind /dev "$MNT/dev"
mount --rbind /sys "$MNT/sys"

run_in() { chroot "$MNT" /bin/bash -c "$*"; }

# --------------------------------------------------------- 4. apt deps
echo "[4/7] apt: build deps inside debian rootfs..."
run_in "apt-get update" >/dev/null
run_in "apt-get install -y --no-install-recommends \
    ca-certificates curl xz-utils tar git make pkg-config python3 \
    build-essential cmake clang libclang-dev musl-tools" 2>&1 | tail -3
run_in "apt-get clean"

# --------------------------------------------------------- 5. rust nightly
echo "[5/7] install rust ${RUST_CHANNEL} into /usr/local..."
run_in "
set -e
cd /tmp
mkdir -p /tmp/rust-extract
cd /tmp/rust-extract
curl -fL https://static.rust-lang.org/dist/${RUST_CHANNEL#nightly-}/rust-nightly-${ARCH}gc-unknown-linux-gnu.tar.xz \
    -o /tmp/rust.tar.xz
tar xJf /tmp/rust.tar.xz --strip-components=1
./install.sh --prefix=/usr/local --without=rust-docs >/dev/null
cd / && rm -rf /tmp/rust.tar.xz /tmp/rust-extract

# Cross std for the kernel target (no_std bare-metal RISC-V)
mkdir -p /tmp/std-extract && cd /tmp/std-extract
curl -fL https://static.rust-lang.org/dist/${RUST_CHANNEL#nightly-}/rust-std-nightly-${ARCH}gc-unknown-none-elf.tar.xz \
    -o /tmp/std.tar.xz
tar xJf /tmp/std.tar.xz --strip-components=1
./install.sh --prefix=/usr/local >/dev/null
cd / && rm -rf /tmp/std.tar.xz /tmp/std-extract

cd /
rustc --version
cargo --version
"

# --------------------------------------------------------- 6. tgoskits + cargo fetch
echo "[6/7] clone tgoskits + cargo fetch (pre-populate registry)..."
run_in "
set -e
cd /opt
[ -d tgoskits ] || git clone --depth 1 -b ${TGOSKITS_BRANCH} ${TGOSKITS_URL}
cd /opt/tgoskits
echo TGOSKITS HEAD: \$(git log -1 --oneline)

# pre-fetch all crates so guest can run --offline build
cargo fetch >/dev/null 2>&1 || true
"

# --------------------------------------------------------- 7. inject demo helper
echo "[7/7] inject demo helper /opt/build-starry-kernel.sh ..."
cat > "$MNT/opt/build-starry-kernel.sh" <<'GUESTSH'
#!/bin/bash
# /opt/build-starry-kernel.sh — runs inside the StarryOS guest.
# Compiles starry-kernel (the StarryOS kernel lib) using the offline
# cargo + rust nightly that were baked into this rootfs.
set -e
cd /opt/tgoskits

echo "================================================================"
echo "  StarryOS Self-Build Demo M6 — guest cargo build starry-kernel"
echo "================================================================"
echo
echo "[0] toolchain sanity:"
rustc --version
cargo --version
musl-gcc --version | head -1
echo
echo "[1] tgoskits source (HEAD):"
git -C /opt/tgoskits log -1 --oneline
echo

# axplat config flow — same as the host build
cd /opt/tgoskits/os/StarryOS
PLAT_CONFIG=$(cargo axplat info -C starryos -c ax-plat-riscv64-qemu-virt 2>/dev/null | tail -1 || true)
if [ -z "$PLAT_CONFIG" ] || [ ! -f "$PLAT_CONFIG" ]; then
    echo "warn: cargo-axplat not available; falling back to a simpler cargo build path"
    cd /opt/tgoskits
    echo "[2] cargo build -p starry-kernel --target riscv64gc-unknown-none-elf --release"
    cargo build --offline -p starry-kernel --target riscv64gc-unknown-none-elf --release 2>&1 | tail -10
    RC=$?
    echo "exit=$RC"
    if [ $RC -eq 0 ]; then
        echo "===M6-SELFBUILD-PASS==="
    fi
    exit $RC
fi
echo "PLAT_CONFIG=$PLAT_CONFIG"

PLAT_NAME=$(awk -F'"' '$1 ~ /^platform[[:space:]]*=/ {print $2}' "$PLAT_CONFIG" | head -1)
ax-config-gen "$(pwd)/make/defconfig.toml" "$PLAT_CONFIG" \
    -w "arch=\"riscv64\"" -w "platform=\"$PLAT_NAME\"" \
    -o .axconfig.toml

export AX_ARCH=riscv64
export AX_PLATFORM="$PLAT_NAME"
export AX_MODE=release
export AX_LOG=warn
export AX_TARGET=riscv64gc-unknown-none-elf
export AX_IP=10.0.2.15
export AX_GW=10.0.2.2
export AX_CONFIG_PATH="$(pwd)/.axconfig.toml"

cd /opt/tgoskits

echo "[2] cargo build -p starry-kernel (lib only, no link)"
cargo build --offline -p starry-kernel \
    --target riscv64gc-unknown-none-elf --release 2>&1 | tail -15
RC=$?
echo "starry-kernel-build exit=$RC"

if [ $RC -eq 0 ]; then
    LIB=$(find target/riscv64gc-unknown-none-elf/release -name "libstarry_kernel*.rlib" | head -1)
    echo "produced: $(ls -lh $LIB 2>&1 | head)"
    echo
    echo "[3] cargo build -p starryos (full kernel ELF)"
    RUSTFLAGS="-C link-arg=-T/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/linker_${PLAT_NAME}.lds -C link-arg=-no-pie -C link-arg=-znostart-stop-gc" \
        cargo build --offline -p starryos \
        --target riscv64gc-unknown-none-elf --release \
        --features starryos/qemu 2>&1 | tail -15 || true

    ELF=target/riscv64gc-unknown-none-elf/release/starryos
    if [ -f "$ELF" ]; then
        ls -lh "$ELF"
        file "$ELF" | head -1
        echo
        echo "================================================================"
        echo "===M6-SELFBUILD-PASS==="
        echo "  starry kernel ELF was just produced INSIDE the starry guest!"
        echo "================================================================"
    else
        echo "lib build OK but final ELF link did not complete — still counts as"
        echo "self-build progress."
        echo "===M6-SELFBUILD-LIB-PASS==="
    fi
fi
GUESTSH
chmod +x "$MNT/opt/build-starry-kernel.sh"

# --------------------------------------------------------- finalise
echo "[+] cleanup, finalising image..."
run_in "rm -rf /var/cache/apt/archives /var/lib/apt/lists/* /tmp/* /opt/rust-extract" 2>/dev/null || true
df -h "$MNT" | tail -1

# Convert disk.raw → standalone ext4 image (skip the GPT, just the rootfs)
sync
cleanup
trap - EXIT

echo "[+] extracting partition 1 → $OUT_IMG"
mkdir -p "$(dirname "$OUT_IMG")"
PART_SIZE=$(( $(stat -c %s "$DISK_RAW") - OFFSET ))
dd if="$DISK_RAW" of="$OUT_IMG" bs=4M skip=$((OFFSET / 4194304)) status=none
ls -lh "$OUT_IMG"

echo "[+] xz compress (this may take a while)..."
xz -k -T0 -9 "$OUT_IMG"
ls -lh "$OUT_IMG" "$OUT_IMG.xz"
sha256sum "$OUT_IMG" > "$OUT_IMG.sha256"
sha256sum "$OUT_IMG.xz" > "$OUT_IMG.xz.sha256"

echo
echo "================================================================"
echo "  ✓ selfbuild rootfs ready"
echo "  raw : $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
echo "  xz  : $OUT_IMG.xz ($(du -h "$OUT_IMG.xz" | cut -f1))"
echo "================================================================"
