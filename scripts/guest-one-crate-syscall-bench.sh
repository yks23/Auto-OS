#!/usr/bin/env bash
# Starry **访客内**真实测量：reset /proc/syscall_stats 后跑一次
#   cargo check -p ax-errno --target riscv64gc-unknown-none-elf
# 再 cat /proc/syscall_stats，从串口日志读取 wall 时间与 total syscall（自 reset 起累计）。
#
# 默认在 Docker（root + privileged）内执行；宿主机直接跑且非 root 时会自行 re-exec docker。
#
# 环境变量：
#   GUEST_BENCH_ROOTFS — 可写 rootfs raw（默认 .guest-runs/riscv64-m6/rootfs-run.img，否则 tests/selfhost/rootfs-selfbuild-riscv64.img）
#   GUEST_BENCH_TIMEOUT — QEMU 外层 timeout 秒数（默认 7200）
#   GUEST_BENCH_CRATE   — workspace 包名（默认 ax-errno）
#   GUEST_BENCH_SKIP_SAVE — 若设为 1，不更新 .guest-runs/saved/ 下内核副本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "GUEST_BENCH_ROOTFS=${GUEST_BENCH_ROOTFS:-}" \
    -e "GUEST_BENCH_TIMEOUT=${GUEST_BENCH_TIMEOUT:-}" \
    -e "GUEST_BENCH_CRATE=${GUEST_BENCH_CRATE:-}" \
    -e "GUEST_BENCH_SKIP_SAVE=${GUEST_BENCH_SKIP_SAVE:-}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-one-crate-syscall-bench.sh
fi

cd /work
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="/work/.guest-runs/saved"
KERNEL_SRC="/work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="/work/.guest-runs/guest-one-crate-bench"
RESULT="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.txt"
MNT=/tmp/guest-bench-rfsmnt
TO="${GUEST_BENCH_TIMEOUT:-7200}"
CRATE="${GUEST_BENCH_CRATE:-ax-errno}"

ROOTFS="${GUEST_BENCH_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "/work/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="/work/.guest-runs/riscv64-m6/rootfs-run.img"
  else
    ROOTFS="/work/tests/selfhost/rootfs-selfbuild-riscv64.img"
  fi
fi

[[ -f "$KERNEL_SRC" ]] || { echo "missing kernel ELF: $KERNEL_SRC"; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS"; exit 1; }

mkdir -p "$SAVE_DIR" "$OUT_DIR"
if [[ "${GUEST_BENCH_SKIP_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  sha256sum "$KERNEL_SAVE" | tee "${KERNEL_SAVE}.sha256" >/dev/null
  echo "[+] saved kernel -> $KERNEL_SAVE"
fi

riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

tee "${MNT}/opt/run-tests.sh" >/dev/null <<EOF
#!/bin/sh
export GUEST_BENCH_CRATE="${CRATE}"
exec /bin/bash --noprofile --norc /opt/guest-one-crate-bench.sh
EOF
chmod +x "${MNT}/opt/run-tests.sh"

tee "${MNT}/opt/guest-one-crate-bench.sh" >/dev/null <<'GBEOF'
#!/bin/bash
set -eo pipefail
CRATE="${GUEST_BENCH_CRATE:-ax-errno}"
echo "===GUEST_ONE_CRATE_BENCH_BEGIN crate=${CRATE}==="
date -u

if ! test -w /proc/syscall_stats_reset 2>/dev/null; then
  echo "===GUEST_BENCH_FAIL no_writable /proc/syscall_stats_reset (kernel too old?)==="
  exit 2
fi
echo x >/proc/syscall_stats_reset

export PATH="/opt/ccwrap:/opt/alpine-rust/usr/bin:/usr/bin:/usr/sbin:/bin:/sbin"
export LD_LIBRARY_PATH="/opt/alpine-rust/lib:/opt/alpine-rust/usr/lib"
export SQLITE_TMPDIR=/opt/tgoskits/.m6-tmp
export TMPDIR=/opt/tgoskits/.m6-tmp
export TMP=/opt/tgoskits/.m6-tmp
export TEMP=/opt/tgoskits/.m6-tmp
/bin/mkdir -p "$TMPDIR" /opt/tgoskits/m6-cargo-home/registry 2>/dev/null || true
export CARGO_HOME="${CARGO_HOME:-/opt/tgoskits/m6-cargo-home}"
export CC="${CC:-/opt/ccwrap/cc}"
export CXX="${CXX:-/opt/ccwrap/c++}"
export RUST_MIN_STACK="${RUST_MIN_STACK:-16777216}"
_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-$_NPROC}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$_NPROC}"
export CARGO_TERM_PROGRESS="${CARGO_TERM_PROGRESS:-wide}"
export CARGO_TERM_VERBOSE="${CARGO_TERM_VERBOSE:-true}"
M6_RUSTFLAGS_COMMON="${M6_RUSTFLAGS_COMMON:--C debuginfo=2}"
export RUSTFLAGS="$M6_RUSTFLAGS_COMMON ${RUSTFLAGS:-}"

# ── Ensure rust-src is available for -Z build-std ──
_RUSTC_BIN="/opt/alpine-rust/usr/bin/rustc"
_SYSROOT="$("$_RUSTC_BIN" --print sysroot 2>/dev/null || echo "/opt/alpine-rust/usr")"
_RUSTLIB_SRC="${_SYSROOT}/lib/rustlib/src/rust"
if [[ ! -f "${_RUSTLIB_SRC}/library/core/Cargo.toml" ]]; then
  if [[ -f "/opt/rust-src-for-rootfs.tar.gz" ]]; then
    echo "[bench] extracting rust-src..."
    rm -rf "${_RUSTLIB_SRC}" 2>/dev/null || true
    mkdir -p "$(dirname "${_RUSTLIB_SRC}")" 2>/dev/null || true
    (cd "$(dirname "${_RUSTLIB_SRC}")" && tar xzf /opt/rust-src-for-rootfs.tar.gz)
  fi
fi

cd /opt/tgoskits
T0=$(date +%s)
echo "[bench] T0=$T0 starting cargo check -p ${CRATE} ..."
set +o pipefail
env PATH="$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
  /opt/alpine-rust/usr/bin/cargo check -p "${CRATE}" --target riscv64gc-unknown-none-elf \
  -Z build-std=core,alloc,compiler_builtins 2>&1 | tee /tmp/guest-one-crate-cargo.log
RC=${PIPESTATUS[0]}
set -o pipefail
T1=$(date +%s)
EL=$((T1 - T0))
echo "===GUEST_ONE_CRATE_BENCH_RC ${RC}==="
echo "===GUEST_ONE_CRATE_BENCH_ELAPSED_S ${EL}==="

echo "===SYSCALL_STATS_AFTER_BEGIN==="
if [ -r /proc/syscall_stats ]; then
  cat /proc/syscall_stats
else
  echo "(no /proc/syscall_stats)"
fi
echo "===SYSCALL_STATS_AFTER_END==="
echo "===GUEST_ONE_CRATE_BENCH_END==="
exit "$RC"
GBEOF
chmod +x "${MNT}/opt/guest-one-crate-bench.sh"

# rustc wrapper: prevent vec_cache.rs:201 ICE under QEMU TCG
mkdir -p "${MNT}/opt/ccwrap"
tee "${MNT}/opt/ccwrap/rustc" >/dev/null <<'RUSTWRAP'
#!/bin/sh
exec env RUSTC_BOOTSTRAP=1 /opt/alpine-rust/usr/bin/rustc -Z threads=0 "$@"
RUSTWRAP
chmod +x "${MNT}/opt/ccwrap/rustc"

umount "$MNT" || { echo "umount failed"; exit 1; }

echo "[+] launching QEMU (timeout ${TO}s) -> $RESULT"
rm -f "$RESULT"
# QEMU TCG LR/SC broken under MTTCG; only need single-threaded TCG when SMP > 1.
_EVSMP="${EVIDENCE_SMP:-1}"
_evtcg=()
if [[ "$_EVSMP" -gt 1 ]]; then _evtcg=(-accel tcg,thread=single); fi
set +e
timeout "$TO" qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp "$_EVSMP" -m 5G \
  "${_evtcg[@]}" \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  >"$RESULT" 2>&1 </dev/null
Q_RC=$?
set -e

echo "[+] qemu exit $Q_RC (124=timeout)"

export GUEST_BENCH_RESULT="$RESULT"
python3 - <<'PY' >"$SUMMARY"
import os, re, sys
from pathlib import Path
p = Path(os.environ["GUEST_BENCH_RESULT"])
raw = p.read_bytes().decode("utf-8", errors="replace")
el = m.group(1) if (m := re.search(r"===GUEST_ONE_CRATE_BENCH_ELAPSED_S (\d+)===" , raw)) else "?"
rc = m.group(1) if (m := re.search(r"===GUEST_ONE_CRATE_BENCH_RC (\d+)===" , raw)) else "?"
# first line starting with total after SYSCALL_STATS_AFTER_BEGIN
blk = re.search(
    r"===SYSCALL_STATS_AFTER_BEGIN===\s*\n(total \d+)",
    raw,
    re.M,
)
total_line = blk.group(1) if blk else "(missing syscall block)"
print("guest_one_crate_bench")
print("  elapsed_s:", el)
print("  cargo_rc:", rc)
print("  syscall_stats_first_line:", total_line)
print("  log:", str(p))
PY

cat "$SUMMARY"
exit 0
