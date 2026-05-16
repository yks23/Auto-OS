#!/usr/bin/env bash
# verify-m6-rootfs.sh — 静态/挂载检查 selfbuild rootfs，**不跑 QEMU**（秒级）。
# 在改完 build-selfbuild-rootfs.sh 或手工改盘后用本脚本形成清晰反馈环：
#   1) bash scripts/verify-m6-rootfs.sh
#   2) 再跑 scripts/demo-m6-selfbuild.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOTFS="${ROOTFS:-$ROOT/tests/selfhost/rootfs-selfbuild-riscv64.img}"
MNT="${MNT:-/tmp/verify-m6-rfs}"

err() { echo "verify-m6-rootfs: $*" >&2; exit 1; }

[[ -f "$ROOTFS" ]] || err "rootfs not found: $ROOTFS"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
M6_QEMU_SMP="${M6_QEMU_SMP:-1}"
M6_QEMU_MEM="${M6_QEMU_MEM:-5G}"

$SUDO umount "$MNT" 2>/dev/null || true
$SUDO mkdir -p "$MNT"
$SUDO mount -o loop "$ROOTFS" "$MNT"

cleanup() { $SUDO umount "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

echo "[1] disk usage on rootfs"
$SUDO df -h "$MNT" | tail -1
avail_kb=$($SUDO df -Pk "$MNT" | awk 'NR==2 {print $4}')
# 至少 ~2GiB 空闲，否则 guest cargo 极易写爆 sqlite/registry
[[ "${avail_kb:-0}" -ge 2000000 ]] || err "free space < 2GiB on $ROOTFS (df -Pk avail_kb=$avail_kb); enlarge image (DISK_SIZE_GB / resize2fs)"

checks=(
  "$MNT/opt/ccwrap/cc"
  "$MNT/opt/alpine-rust/usr/bin/cargo"
  "$MNT/opt/alpine-rust/usr/bin/rustc"
  "$MNT/opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc"
  "$MNT/opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-g++"
  "$MNT/opt/tgoskits/m6-cargo-home"
  "$MNT/opt/tgoskits/Cargo.toml"
  "$MNT/opt/tgoskits/os/StarryOS/.axconfig.toml"
  "$MNT/opt/tgoskits/components/axplat_crates/platforms/axplat-riscv64-qemu-virt/axconfig.toml"
  "$MNT/opt/build-starry-kernel.sh"
  "$MNT/etc/ld-musl-riscv64.path"
)
for p in "${checks[@]}"; do
  $SUDO test -e "$p" || err "missing: $p"
done

echo "[1a] Alpine musl rust layout"
$SUDO grep -qF '/opt/alpine-rust/lib' "$MNT/etc/ld-musl-riscv64.path" || err "ld-musl path missing /opt/alpine-rust/lib"
$SUDO grep -qF '/opt/alpine-rust/usr/lib' "$MNT/etc/ld-musl-riscv64.path" || err "ld-musl path missing /opt/alpine-rust/usr/lib"
if $SUDO test -e "$MNT/opt/alpine-rust/usr/lib/libscudo.so"; then
  $SUDO test -L "$MNT/opt/alpine-rust/usr/lib/libscudo.so" || err "libscudo.so must be a symlink for QEMU TCG stability"
fi
$SUDO test -f "$MNT/opt/alpine-rust/usr/lib/rustlib/src/rust/library/core/Cargo.toml" || err "missing rust-src core Cargo.toml under /opt/alpine-rust"

echo "[1b] ccwrap should clear LD_LIBRARY_PATH and delegate to a known linker driver (demo overwrites old images)"
if $SUDO grep -qF 'unset LD_LIBRARY_PATH' "$MNT/opt/ccwrap/cc" 2>/dev/null && \
   { $SUDO grep -qF '/opt/alpine-rust/usr/bin/riscv64-alpine-linux-musl-gcc' "$MNT/opt/ccwrap/cc" 2>/dev/null || \
     $SUDO grep -qF '/usr/bin/clang' "$MNT/opt/ccwrap/cc" 2>/dev/null; }; then
  echo "  OK (on-disk image already has fixed ccwrap)"
else
  echo "  warn: on-disk ccwrap predates fix — scripts/demo-m6-selfbuild.sh overwrites /opt/ccwrap/cc when injecting run-tests"
fi

echo "[1c] axconfig must export ax_config::TASK_STACK_SIZE"
AXCFG="$MNT/opt/tgoskits/os/StarryOS/.axconfig.toml"
if ! $SUDO grep -qE '^[[:space:]]*task-stack-size[[:space:]]*=' "$AXCFG"; then
  err "missing task-stack-size in os/StarryOS/.axconfig.toml; demo script can patch it, but rebuild the rootfs for a clean image"
fi
for re in \
  '^[[:space:]]*arch[[:space:]]*=[[:space:]]*"riscv64"' \
  '^[[:space:]]*platform[[:space:]]*=[[:space:]]*"riscv64-qemu-virt"' \
  '^[[:space:]]*ticks-per-sec[[:space:]]*=' \
  '^[[:space:]]*max-cpu-num[[:space:]]*=' \
  '^[[:space:]]*phys-memory-size[[:space:]]*=' \
  '^[[:space:]]*kernel-base-paddr[[:space:]]*=' \
  '^[[:space:]]*kernel-base-vaddr[[:space:]]*=' \
  '^[[:space:]]*phys-virt-offset[[:space:]]*='; do
  $SUDO grep -qE "$re" "$AXCFG" || err "axconfig missing expected field matching: $re"
done
max_cpu=$($SUDO awk -F= '$1 ~ /^[[:space:]]*max-cpu-num[[:space:]]*$/ {gsub(/[ #].*/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit}' "$AXCFG")
case "${max_cpu:-}" in ''|*[!0-9]*) err "cannot parse plat.max-cpu-num from .axconfig.toml: ${max_cpu:-<empty>}" ;; esac
[[ "$M6_QEMU_SMP" -le "$max_cpu" ]] || err "M6_QEMU_SMP=$M6_QEMU_SMP exceeds plat.max-cpu-num=$max_cpu"

echo "[2] cargo registry present (host cargo fetch output)"
reg="$MNT/opt/cargo-home/registry"
if ! $SUDO test -d "$reg"; then
    reg="$MNT/opt/tgoskits/m6-cargo-home/registry"
fi
$SUDO test -d "$reg" || err "missing $reg"
$SUDO test -d "$reg/src" || $SUDO test -d "$reg/cache" || err "registry has no src/ or cache/ under $reg (cargo fetch incomplete?)"

echo "[3] baked guest script sanity"
$SUDO test -x "$MNT/opt/build-starry-kernel.sh" || err "build-starry-kernel.sh not executable"
$SUDO bash -n "$MNT/opt/build-starry-kernel.sh" || err "bash -n failed on /opt/build-starry-kernel.sh"
for needle in '/opt/ccwrap' 'TMPDIR=/opt/tgoskits/.m6-tmp' 'm6-cargo-home' 'set -e' 'LD_LIBRARY_PATH="/opt/alpine-rust/lib' 'tee /tmp/m6-cargo' 'M6-SELFBUILD-PASS'; do
  $SUDO grep -qF "$needle" "$MNT/opt/build-starry-kernel.sh" || err "guest script missing expected line: $needle"
done

echo "[3b] target directory shape sanity"
bad_dirs=$($SUDO find "$MNT/opt/tgoskits/target/release/build" -mindepth 2 -maxdepth 2 -type d -name build-script-build -print 2>/dev/null | head -5 || true)
if [[ -n "$bad_dirs" ]]; then
  echo "$bad_dirs" >&2
  err "cargo target corruption: build-script-build is a directory; remove target/release/build/*/build-script-build or rebuild the rootfs target cache"
fi

echo "[4] tarball copy must not ship broken .git (optional)"
if $SUDO test -e "$MNT/opt/tgoskits/.git"; then
  echo "  warn: /opt/tgoskits/.git exists — guest git may confuse submodule paths"
fi

echo "OK — rootfs passes verify-m6-rootfs.sh (mount checks only, no QEMU)"
