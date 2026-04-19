#!/usr/bin/env bash
# 基于 Alpine 3.21 minirootfs 构建带 musl-gcc / binutils / make 的 ext4 镜像，供 StarryOS self-host 使用。
#
# 用法（在 Auto-OS 仓根目录执行）：
#   sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=x86_64
#   sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=x86_64 PROFILE=rust
#   sudo bash tests/selfhost/build-selfhost-rootfs.sh ARCH=riscv64   # 需 qemu-riscv64-static + binfmt（否则退出码 2）
#
# 产出（默认不入 git，见 tests/selfhost/.gitignore）：
#   PROFILE=minimal → tests/selfhost/rootfs-selfhost-${ARCH}.img (+ .xz)
#   PROFILE=rust    → tests/selfhost/rootfs-selfhost-rust-${ARCH}.img (+ .xz)
#
# 依赖：curl、tar、xz、e2fsprogs(mkfs.ext4)、sudo、chroot；跨架构还需 qemu-*-static 与 binfmt_misc。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: 请用 root 运行（需要 mount/chroot/mkfs）: sudo bash $0 ..." >&2
  exit 1
fi

ARCH="x86_64"
PROFILE="minimal"
for arg in "$@"; do
  case "$arg" in
    ARCH=*) ARCH="${arg#ARCH=}" ;;
    PROFILE=*) PROFILE="${arg#PROFILE=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

HOST_ARCH="$(uname -m)"
ALPINE_DOT="3.21.0"
ALPINE_REL="v3.21"
BASE_URL="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_REL}/releases"

case "$ARCH" in
  x86_64 | riscv64) ;;
  *) echo "error: unsupported ARCH=$ARCH (only x86_64|riscv64)" >&2; exit 1 ;;
esac

case "$PROFILE" in
  minimal | rust) ;;
  *) echo "error: unsupported PROFILE=$PROFILE (only minimal|rust)" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64) ALP_ARCH="x86_64" ;;
  riscv64) ALP_ARCH="riscv64" ;;
esac

TARBALL="alpine-minirootfs-${ALPINE_DOT}-${ALP_ARCH}.tar.gz"
URL="${BASE_URL}/${ALP_ARCH}/${TARBALL}"

if [[ "$PROFILE" == "rust" ]]; then
  OUT_BASE="$SCRIPT_DIR/rootfs-selfhost-rust-${ARCH}"
else
  OUT_BASE="$SCRIPT_DIR/rootfs-selfhost-${ARCH}"
fi
OUT_IMG="${OUT_BASE}.img"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/starry-selfhost-rootfs.XXXXXX")"
ROOT_DIR="$WORKDIR/root"
mkdir -p "$ROOT_DIR"

cleanup_mounts() {
  umount "$ROOT_DIR/proc" 2>/dev/null || true
  umount -R "$ROOT_DIR/dev" 2>/dev/null || true
  umount -R "$ROOT_DIR/sys" 2>/dev/null || true
}
trap 'cleanup_mounts; rm -rf "$WORKDIR"' EXIT

echo "[+] download $URL"
curl -fL "$URL" -o "$WORKDIR/$TARBALL"
tar xzf "$WORKDIR/$TARBALL" -C "$ROOT_DIR"

mkdir -p "$ROOT_DIR"/{proc,sys,dev/pts}

cross=0
if [[ "$ARCH" != "$HOST_ARCH" ]]; then
  cross=1
fi

if (( cross )); then
  case "$ARCH" in
    riscv64) QBIN="qemu-riscv64-static" ;;
    *) echo "error: cross build from $HOST_ARCH to $ARCH not wired" >&2; exit 2 ;;
  esac
  if ! command -v "$QBIN" >/dev/null 2>&1; then
    echo "error: 需要 $QBIN 才能 chroot 到 $ARCH Alpine（本机缺失，riscv64 标 SKIP，见 SELFHOST-ROOTFS.md）" >&2
    exit 2
  fi
  mkdir -p "$ROOT_DIR/usr/bin"
  cp -f "$(command -v "$QBIN")" "$ROOT_DIR/usr/bin/$QBIN"
  if [[ ! -f /proc/sys/fs/binfmt_misc/register ]]; then
    echo "error: binfmt_misc 不可用，无法执行 $ARCH 用户态" >&2
    exit 2
  fi
fi

mount -t proc /proc "$ROOT_DIR/proc"
mount --rbind /dev "$ROOT_DIR/dev"
mount --rbind /sys "$ROOT_DIR/sys"
cp /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"

run_in_root() {
  chroot "$ROOT_DIR" /bin/sh -c "$1"
}

echo "[+] apk update / install toolchain"
run_in_root "/sbin/apk update"
run_in_root "/sbin/apk add --no-cache build-base make bash coreutils findutils grep sed gawk"

if [[ "$PROFILE" == "rust" ]]; then
  echo "[+] apk rust/cargo (体积大，耗时久)"
  run_in_root "/sbin/apk add --no-cache rust cargo"
fi

echo "[+] Starry selfhost 目录（run-tests-in-guest 会注入 /opt/run-tests.sh 与 test_*）"
mkdir -p "$ROOT_DIR/opt/selfhost-tests"
{
  echo "# 由 tests/selfhost/build-selfhost-rootfs.sh 创建"
  echo "# Starry init.sh（内核内嵌）若发现 /opt/run-tests.sh 会 exec；此处仅占位目录。"
} >"$ROOT_DIR/opt/selfhost-tests/README.txt"

cleanup_mounts
trap 'rm -rf "$WORKDIR"' EXIT

USED_K="$(du -sk "$ROOT_DIR" | awk '{print $1}')"
# ext4 预留 ~35% 元数据与其它开销
SIZE_K=$(( USED_K + USED_K / 3 + 50000 ))
if [[ "$PROFILE" == "rust" ]]; then
  MIN_K=$((4000 * 1024))
  [[ "$SIZE_K" -lt "$MIN_K" ]] && SIZE_K="$MIN_K"
else
  MIN_K=$((700 * 1024))
  [[ "$SIZE_K" -lt "$MIN_K" ]] && SIZE_K="$MIN_K"
fi

echo "[+] mkfs.ext4 (data ~${USED_K}KiB → image ~${SIZE_K}KiB)"
truncate -s "${SIZE_K}K" "$OUT_IMG"
# ext4 卷标最长 16 字节
case "$PROFILE" in
  minimal) E2LABEL="starry-sf-min" ;;
  rust) E2LABEL="starry-sf-rust" ;;
esac
mkfs.ext4 -F -L "$E2LABEL" -d "$ROOT_DIR" "$OUT_IMG"

echo "[+] xz -k"
xz -k -6 -T0 "$OUT_IMG"

echo "[+] sha256"
sha256sum "$OUT_IMG" | tee "${OUT_IMG}.sha256"

echo "[+] done: $OUT_IMG ($(du -h "$OUT_IMG" | awk '{print $1}'))"
