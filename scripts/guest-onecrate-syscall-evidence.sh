#!/usr/bin/env bash
# QEMU 内 Starry 访客：syscall 采样 + 受控编译（见 scripts/guest-onecrate-inner.sh）。
# 限时：QEMU 外层 timeout（默认 7200s）；宿主 orchestrator 另包一层。
#
# 控制变量（无网络）：
#   GUEST_ONECRATE_ALLOW_FETCH=0（默认）— 不跑 cargo fetch；须 rootfs 内 CARGO_HOME 已具备离线依赖。
#   GUEST_ONECRATE_MODE=rustc — 最简：rustc 将 /opt/tiny/hello.rs 编译为 object（--emit=obj），无 cargo、无 registry、不跑访客链接器。
#   GUEST_ONECRATE_MODE=cargo — cargo check -p … --offline（默认，与宿主 onecrate 对齐时显式传入）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  exec docker run --rm --privileged --network host \
    -v "${REPO}:/work" -w /work \
    -e "GUEST_ONECRATE_ROOTFS=${GUEST_ONECRATE_ROOTFS:-}" \
    -e "GUEST_ONECRATE_TIMEOUT=${GUEST_ONECRATE_TIMEOUT:-}" \
    -e "GUEST_ONECRATE_SKIP_KERNEL_SAVE=${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-}" \
    -e "GUEST_ONECRATE_CRATE=${GUEST_ONECRATE_CRATE:-}" \
    -e "GUEST_ONECRATE_TARGET=${GUEST_ONECRATE_TARGET:-}" \
    -e "GUEST_ONECRATE_SAMPLE_SLEEP=${GUEST_ONECRATE_SAMPLE_SLEEP:-}" \
    -e "GUEST_ONECRATE_MODE=${GUEST_ONECRATE_MODE:-cargo}" \
    -e "GUEST_ONECRATE_ALLOW_FETCH=${GUEST_ONECRATE_ALLOW_FETCH:-0}" \
    auto-os/starry:latest \
    bash /work/scripts/guest-onecrate-syscall-evidence.sh
fi

cd /work
export PATH="/opt/riscv64-linux-musl-cross/bin:${PATH:-}"

SAVE_DIR="/work/.guest-runs/saved"
KERNEL_SRC="/work/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
KERNEL_SAVE="${SAVE_DIR}/starryos-riscv64.release"
KERNEL_BIN="${SAVE_DIR}/starryos-riscv64.release.bin"
OUT_DIR="/work/.guest-runs/guest-onecrate-bench"
RESULT="${OUT_DIR}/results.txt"
SUMMARY="${OUT_DIR}/summary.txt"
MNT=/tmp/guest-onecrate-mnt
TO="${GUEST_ONECRATE_TIMEOUT:-7200}"

ROOTFS="${GUEST_ONECRATE_ROOTFS:-}"
if [[ -z "$ROOTFS" ]]; then
  if [[ -f "/work/.guest-runs/riscv64-m6/rootfs-run.img" ]]; then
    ROOTFS="/work/.guest-runs/riscv64-m6/rootfs-run.img"
  else
    ROOTFS="/work/tests/selfhost/rootfs-selfbuild-riscv64.img"
  fi
fi

[[ -f "$KERNEL_SRC" ]] || { echo "missing kernel ELF: $KERNEL_SRC"; exit 1; }
[[ -f "$ROOTFS" ]] || { echo "missing rootfs: $ROOTFS"; exit 1; }
[[ -f "/work/scripts/guest-onecrate-inner.sh" ]] || { echo "missing /work/scripts/guest-onecrate-inner.sh"; exit 1; }

mkdir -p "$SAVE_DIR" "$OUT_DIR"
if [[ "${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-0}" != "1" ]]; then
  cp -f "$KERNEL_SRC" "$KERNEL_SAVE"
  sha256sum "$KERNEL_SAVE" >"${KERNEL_SAVE}.sha256"
fi
riscv64-linux-musl-objcopy -O binary "$KERNEL_SAVE" "$KERNEL_BIN"

umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT"
mount -o loop,rw "$ROOTFS" "$MNT"

CRATE="${GUEST_ONECRATE_CRATE:-ax-errno}"
TARGET="${GUEST_ONECRATE_TARGET:-riscv64gc-unknown-none-elf}"
SLEEP="${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}"
# 默认 cargo（与旧行为一致）；受控最简：GUEST_ONECRATE_MODE=rustc GUEST_ONECRATE_ALLOW_FETCH=0
ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
# `set -u` 下，未引用的 heredoc 展开若出现未赋值名（例如误写 ${MODE}）会直接失败；此处先 export 默认值，heredoc 只引用已定义名。
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE:-cargo}"
export GUEST_ONECRATE_ALLOW_FETCH="${ALLOW_FETCH}"

mkdir -p "${MNT}/opt/tiny"
# rustc 最简受控路径（无 cargo、无网络）；cargo 模式时亦存在，无害。
cat >"${MNT}/opt/tiny/hello.rs" <<'HELLO'
fn main() {}
HELLO

tee "${MNT}/opt/run-tests.sh" >/dev/null <<EOF
#!/bin/sh
export GUEST_ONECRATE_CRATE="${CRATE}"
export GUEST_ONECRATE_TARGET="${TARGET}"
export GUEST_ONECRATE_SAMPLE_SLEEP="${SLEEP}"
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE}"
export GUEST_ONECRATE_ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH}"
exec /bin/bash --noprofile --norc /opt/guest-onecrate-inner.sh
EOF
chmod +x "${MNT}/opt/run-tests.sh"
cp -f "/work/scripts/guest-onecrate-inner.sh" "${MNT}/opt/guest-onecrate-inner.sh"
chmod +x "${MNT}/opt/guest-onecrate-inner.sh"

umount "$MNT" || { echo "umount failed"; exit 1; }

echo "[+] QEMU timeout=${TO}s -> $RESULT"
rm -f "$RESULT" "$SUMMARY"
set +e
timeout "$TO" qemu-system-riscv64 \
  -nographic -machine virt -bios default -smp 4 -m 5G \
  -kernel "$KERNEL_BIN" -cpu rv64 \
  -monitor none -serial mon:stdio \
  -device virtio-blk-pci,drive=disk0 \
  -drive id=disk0,if=none,format=raw,file="$ROOTFS",file.locking=off \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  >"$RESULT" 2>&1 </dev/null
Q_RC=$?
set -e

export GUEST_ONECRATE_RESULT="$RESULT"
export GUEST_ONECRATE_Q_RC="$Q_RC"
python3 - <<'PY' | tee "$SUMMARY"
import os, re
from pathlib import Path
p = Path(os.environ["GUEST_ONECRATE_RESULT"])
raw = p.read_bytes().decode("utf-8", errors="replace")
rc = m.group(1) if (m := re.search(r"===GUEST_ONECRATE_CHECK_RC (\d+)===" , raw)) else "?"
el = m.group(1) if (m := re.search(r"===GUEST_ONECRATE_ELAPSED_S (\d+)===" , raw)) else "?"
blk = re.search(r"===SYSCALL_STATS_AFTER_BEGIN===\s*\n(total \d+)", raw, re.M)
total_line = blk.group(1) if blk else "?"
ok = blk is not None and rc == "0"
print("=== guest_onecrate_syscall_evidence ===")
print("ok:", ok)
print("cargo_check_rc:", rc)
print("elapsed_s:", el)
print("syscall_stats_first_line:", total_line)
print("serial_log:", str(p))
print("qemu_outer_exit:", os.environ.get("GUEST_ONECRATE_Q_RC", "?"))
PY

if [[ "$Q_RC" -eq 124 ]]; then
  echo "[+] qemu outer exit=$Q_RC (timeout(1) killed QEMU)"
else
  echo "[+] qemu outer exit=$Q_RC"
fi

# 供宿主/CI 判断：必须在本轮串口里看到 rustc/cargo 成功标记（禁止仅靠旧 results.txt 冒充通过）。
if [[ ! -s "$RESULT" ]]; then
  echo "[!] serial log empty: $RESULT"
  exit 1
fi
if ! grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT"; then
  echo "[!] missing ===GUEST_ONECRATE_CHECK_RC 0=== in $RESULT (qemu_exit=$Q_RC)"
  exit 1
fi
