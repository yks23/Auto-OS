#!/usr/bin/env bash
# **证据链**：QEMU 内 Starry 访客执行真实 `cargo`，并在同一内核上读取
# `/proc/syscall_stats`（先 reset，再跑 cargo，再 cat）。
#
# 默认跑 **`cargo metadata --offline --no-deps`**（与 M6 subset 第一步同类），在 TCG 下比
# `cargo check` 快得多，仍能产生大量真实 syscall，便于固定证据。
#
# 用法（仓库根，推荐 Docker 自动 re-exec）：
#   bash scripts/guest-cargo-syscall-evidence.sh
# 环境变量：
#   GUEST_EVIDENCE_ROOTFS — rootfs raw（默认同 guest-one-crate-bench）
#   GUEST_EVIDENCE_TIMEOUT — QEMU timeout 秒（默认 1800）
#   GUEST_EVIDENCE_SKIP_KERNEL_SAVE — 设为 1 则跳过复制内核到 .guest-runs/saved/
#   GUEST_SYSCALL_SAMPLE_SLEEP — 访客内采样间隔秒（默认 0.2；与宿主小桶对齐时可改）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "GUEST_EVIDENCE_ROOTFS=${GUEST_EVIDENCE_ROOTFS:-}" \
    -e "GUEST_EVIDENCE_TIMEOUT=${GUEST_EVIDENCE_TIMEOUT:-}" \
    -e "GUEST_EVIDENCE_SKIP_KERNEL_SAVE=${GUEST_EVIDENCE_SKIP_KERNEL_SAVE:-}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-cargo-syscall-evidence.sh
fi

cd /work
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="/work/.guest-runs/saved"
KERNEL_SRC="/work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="/work/.guest-runs/guest-cargo-evidence"
RESULT="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.txt"
MNT=/tmp/guest-evidence-mnt
TO="${GUEST_EVIDENCE_TIMEOUT:-1800}"

ROOTFS="${GUEST_EVIDENCE_ROOTFS:-}"
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
if [[ "${GUEST_EVIDENCE_SKIP_KERNEL_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  sha256sum "$KERNEL_SAVE" >"${KERNEL_SAVE}.sha256"
fi
riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

tee "${MNT}/opt/run-tests.sh" >/dev/null <<'RTEOF'
#!/bin/sh
exec /bin/bash --noprofile --norc /opt/guest-cargo-syscall-evidence-inner.sh
RTEOF
chmod +x "${MNT}/opt/run-tests.sh"

tee "${MNT}/opt/guest-cargo-syscall-evidence-inner.sh" >/dev/null <<'INNER'
#!/bin/bash
set -eo pipefail
echo "===GUEST_CARGO_SYSCALL_EVIDENCE_BEGIN==="
date -u

if ! test -w /proc/syscall_stats_reset 2>/dev/null; then
  echo "===GUEST_EVIDENCE_FAIL no /proc/syscall_stats_reset (need kernel with syscall stats)==="
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

cd /opt/tgoskits
T0=$(date +%s)
echo "[evidence] running: cargo metadata --offline --format-version 1 --no-deps (with periodic syscall total samples)"
# 对齐协议：cargo 在后台跑，期间周期性读 /proc/syscall_stats 首行 total（与宿主 strace 时间桶对照用）。
env PATH="$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" SQLITE_TMPDIR="$SQLITE_TMPDIR" TMPDIR="$TMPDIR" \
  /opt/alpine-rust/usr/bin/cargo metadata --offline --format-version 1 --no-deps > /tmp/guest-evidence-metadata.json 2>&1 &
CPID=$!
SLEEP_SEC="${GUEST_SYSCALL_SAMPLE_SLEEP:-0.2}"
while kill -0 "${CPID}" 2>/dev/null; do
  _w=$(( $(date +%s) - T0 ))
  _tot="?"
  if [ -r /proc/syscall_stats ]; then
    _tot="$(head -1 /proc/syscall_stats 2>/dev/null | awk '{print $2}')"
  fi
  echo "===SYSCALL_SAMPLE rel_s=${_w} total=${_tot}"
  # shellcheck disable=SC2086
  sleep ${SLEEP_SEC}
done
wait "${CPID}"
RC=$?
T1=$(date +%s)
EL=$((T1 - T0))
echo "===GUEST_CARGO_METADATA_RC ${RC}==="
echo "===GUEST_CARGO_METADATA_ELAPSED_S ${EL}==="
echo "metadata_json_bytes=$(wc -c </tmp/guest-evidence-metadata.json 2>/dev/null || echo 0)"
echo "===SYSCALL_STATS_AFTER_BEGIN==="
cat /proc/syscall_stats
echo "===SYSCALL_STATS_AFTER_END==="
echo "===GUEST_CARGO_SYSCALL_EVIDENCE_END==="
exit "$RC"
INNER
chmod +x "${MNT}/opt/guest-cargo-syscall-evidence-inner.sh"

umount "$MNT" || { echo "umount failed"; exit 1; }

echo "[+] QEMU timeout=${TO}s serial -> $RESULT"
rm -f "$RESULT" "$SUMMARY"
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

export GUEST_EVIDENCE_RESULT="$RESULT"
export GUEST_EVIDENCE_Q_RC="$Q_RC"
python3 - <<'PY' | tee "$SUMMARY"
import os, re
from pathlib import Path
p = Path(os.environ["GUEST_EVIDENCE_RESULT"])
raw = p.read_bytes().decode("utf-8", errors="replace")
rc = m.group(1) if (m := re.search(r"===GUEST_CARGO_METADATA_RC (\d+)===" , raw)) else "?"
el = m.group(1) if (m := re.search(r"===GUEST_CARGO_METADATA_ELAPSED_S (\d+)===" , raw)) else "?"
blk = re.search(r"===SYSCALL_STATS_AFTER_BEGIN===\s*\n(total \d+)", raw, re.M)
total_line = blk.group(1) if blk else "(no syscall block — kernel lacks /proc/syscall_stats?)"
ok = blk is not None and rc == "0"
print("=== guest_cargo_syscall_evidence ===")
print("ok:", ok)
print("cargo_metadata_rc:", rc)
print("elapsed_s:", el)
print("syscall_stats_first_line:", total_line)
print("serial_log:", str(p))
print("qemu_outer_exit:", os.environ.get("GUEST_EVIDENCE_Q_RC", "?"))
PY

echo "[+] done qemu outer exit=$Q_RC (124=timeout)"
