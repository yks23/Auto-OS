#!/usr/bin/env bash
# QEMU 内 Starry 访客：syscall 采样 + Phase2 无菌多 crate/workspace（见 scripts/guest-sterile-phase2-inner.sh）。
# 限时：QEMU 外层 timeout（默认 7200s）；宿主 orchestrator 另包一层。
#
# 控制变量（无网络）：
#   STERILE_P2_ALLOW_FETCH=0（默认）— 不跑 cargo fetch；须 rootfs 内 CARGO_HOME 已具备离线依赖。
#   STERILE_P2_MODE=rustc — 同 workspace 下 rustc rlib + app --emit=obj，无 cargo。
#   STERILE_P2_MODE=cargo — cargo check -p app --offline（默认）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "STERILE_P2_ROOTFS=${STERILE_P2_ROOTFS:-}" \
    -e "STERILE_P2_TIMEOUT=${STERILE_P2_TIMEOUT:-}" \
    -e "STERILE_P2_SKIP_KERNEL_SAVE=${STERILE_P2_SKIP_KERNEL_SAVE:-}" \
    -e "STERILE_P2_TARGET=${STERILE_P2_TARGET:-}" \
    -e "STERILE_P2_SAMPLE_SLEEP=${STERILE_P2_SAMPLE_SLEEP:-}" \
    -e "STERILE_P2_MODE=${STERILE_P2_MODE:-cargo}" \
    -e "STERILE_P2_ALLOW_FETCH=${STERILE_P2_ALLOW_FETCH:-0}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-sterile-phase2-evidence.sh
fi

cd /work
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="/work/.guest-runs/saved"
KERNEL_SRC="/work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="/work/.guest-runs/guest-sterile-phase2-bench"
RESULT="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.txt"
MNT=/tmp/guest-sterile-p2-mnt
TO="${STERILE_P2_TIMEOUT:-7200}"

ROOTFS="${STERILE_P2_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "/work/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="/work/.guest-runs/riscv64-m6/rootfs-run.img"
  else
    ROOTFS="/work/tests/selfhost/rootfs-selfbuild-riscv64.img"
  fi
fi

WS_SRC="/work/tests/sterile/minimal-workspace"

[[ -f "$KERNEL_SRC" ]] || { echo "missing kernel ELF: $KERNEL_SRC"; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS"; exit 1; }
[[ -f "/work/scripts/guest-sterile-phase2-inner.sh" ]] || { echo "missing /work/scripts/guest-sterile-phase2-inner.sh"; exit 1; }
[[ -d "$WS_SRC" ]] || { echo "missing workspace: $WS_SRC"; exit 1; }

mkdir -p "$SAVE_DIR" "$OUT_DIR"
if [[ "${STERILE_P2_SKIP_KERNEL_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  sha256sum "$KERNEL_SAVE" >"${KERNEL_SAVE}.sha256"
fi
riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

# Replace libscudo.so with musl symlink — crashes under QEMU TCG
if [[ -f "${MNT}/opt/alpine-rust/usr/lib/libscudo.so" && ! -L "${MNT}/opt/alpine-rust/usr/lib/libscudo.so" ]]; then
  rm -f "${MNT}/opt/alpine-rust/usr/lib/libscudo.so"
  ln -sf /lib/libc.musl-riscv64.so.1 "${MNT}/opt/alpine-rust/usr/lib/libscudo.so"
fi

TARGET="${STERILE_P2_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP="${STERILE_P2_SAMPLE_SLEEP:-0.5}"
ALLOW_FETCH="${STERILE_P2_ALLOW_FETCH:-0}"
export STERILE_P2_MODE="${STERILE_P2_MODE:-cargo}"
export STERILE_P2_ALLOW_FETCH="${ALLOW_FETCH}"

mkdir -p "${MNT}/opt/sterile/minimal-workspace"
cp -a "${WS_SRC}/." "${MNT}/opt/sterile/minimal-workspace/"

tee "${MNT}/opt/run-tests.sh" >/dev/null <<EOF
#!/bin/sh
export STERILE_P2_TARGET="${TARGET}"
export STERILE_P2_SAMPLE_SLEEP="${SLEEP}"
export STERILE_P2_MODE="${STERILE_P2_MODE}"
export STERILE_P2_ALLOW_FETCH="${STERILE_P2_ALLOW_FETCH}"
exec /bin/bash --noprofile --norc /opt/guest-sterile-phase2-inner.sh
EOF
chmod +x "${MNT}/opt/run-tests.sh"
cp -f "/work/scripts/guest-sterile-phase2-inner.sh" "${MNT}/opt/guest-sterile-phase2-inner.sh"
chmod +x "${MNT}/opt/guest-sterile-phase2-inner.sh"

umount "$MNT" || { echo "umount failed"; exit 1; }

echo "[+] QEMU timeout=${TO}s -> $RESULT"
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

export STERILE_P2_RESULT="$RESULT"
export STERILE_P2_Q_RC="$Q_RC"
python3 - <<'PY' | tee "$SUMMARY"
import os, re
from pathlib import Path
p = Path(os.environ["STERILE_P2_RESULT"])
raw = p.read_bytes().decode("utf-8", errors="replace")
rc = m.group(1) if (m := re.search(r"===STERILE_P2_CHECK_RC (\d+)===" , raw)) else "?"
el = m.group(1) if (m := re.search(r"===STERILE_P2_ELAPSED_S (\d+)===" , raw)) else "?"
blk = re.search(r"===SYSCALL_STATS_AFTER_BEGIN===\s*\n(total \d+)", raw, re.M)
total_line = blk.group(1) if blk else "?"
ok = blk is not None and rc == "0"
print("=== guest_sterile_phase2_syscall_evidence ===")
print("ok:", ok)
print("check_rc:", rc)
print("elapsed_s:", el)
print("syscall_stats_first_line:", total_line)
print("serial_log:", str(p))
print("qemu_outer_exit:", os.environ.get("STERILE_P2_Q_RC", "?"))
PY

if [[ "$Q_RC" -eq 124 ]]; then
  echo "[+] qemu outer exit=$Q_RC (timeout(1) killed QEMU)"
else
  echo "[+] qemu outer exit=$Q_RC"
fi
