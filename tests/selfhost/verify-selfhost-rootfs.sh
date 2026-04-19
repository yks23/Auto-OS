#!/usr/bin/env bash
# 在 host 上挂载 ext4 镜像并 chroot 校验 gcc / make / ld（可选 rustc）。
#
# 用法：
#   sudo bash tests/selfhost/verify-selfhost-rootfs.sh tests/selfhost/rootfs-selfhost-x86_64.img
#   sudo bash tests/selfhost/verify-selfhost-rootfs.sh tests/selfhost/rootfs-selfhost-rust-x86_64.img --rust
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: 需要 root（mount + chroot）" >&2
  exit 1
fi

IMG=""
CHECK_RUST=0
for arg in "$@"; do
  case "$arg" in
    --rust) CHECK_RUST=1 ;;
    *) IMG="$arg" ;;
  esac
done

[[ -n "$IMG" && -f "$IMG" ]] || { echo "usage: sudo bash $0 <rootfs.img> [--rust]" >&2; exit 1; }

MNT="$(mktemp -d "${TMPDIR:-/tmp}/verify-selfhost-rootfs.XXXXXX")"
mount -o loop "$IMG" "$MNT"
trap 'umount "$MNT"; rmdir "$MNT"' EXIT

echo "== gcc =="
chroot "$MNT" /bin/sh -c '/usr/bin/gcc --version 2>&1 | head -n1'

echo "== make =="
chroot "$MNT" /bin/sh -c '/usr/bin/make --version 2>&1 | head -n1'

echo "== ld =="
chroot "$MNT" /bin/sh -c '/usr/bin/ld --version 2>&1 | head -n1'

if (( CHECK_RUST )); then
  echo "== rustc =="
  chroot "$MNT" /bin/sh -c '/usr/bin/rustc --version 2>&1 | head -n1'
  echo "== cargo =="
  chroot "$MNT" /bin/sh -c '/usr/bin/cargo --version 2>&1 | head -n1'
fi

echo "OK: verify-selfhost-rootfs"
