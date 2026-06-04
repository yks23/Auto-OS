#!/usr/bin/env bash
# bench-m6-guest-starryos-time.sh — 访客内真实编 starry-kernel + starryos，并输出墙钟与串口阶段戳。
#
# 用法（仓库根，建议在 auto-os/starry Docker root + --privileged 下）：
#   ROOTFS=/path/to/rootfs-selfbuild-riscv64.img bash scripts/bench-m6-guest-starryos-time.sh
#
# 环境变量（可选）：
#   M6_QEMU_TIMEOUT_SEC — 默认 28800（8h）；TCG 下完整编常需数小时。
#   M6_QEMU_MEM / M6_QEMU_SMP / CARGO_BUILD_JOBS / RAYON_NUM_THREADS — 与 demo-m6 一致。
#   M6_RESUME=1 — 与 demo 相同：同一 ROOTFS 上续跑（见 docs/STARRYOS-M6-SELFBUILD-FULL-CROSSCHECK-REPORT.md）。
#
# 另一终端可看阶段行（strings + grep，不抢串口文件锁）：
#   bash scripts/m6-selfbuild-watch.sh
#   M6_RESUME=1 — 与 demo 相同：同一 ROOTFS 上续跑（跳过盘上已有阶段）。
#
# 进度：另开终端 `bash scripts/m6-watch-progress.sh` 或 `tail -f .guest-runs/riscv64-m6/m6-progress.log`
#
# 输出：
#   .guest-runs/riscv64-m6/bench-selfbuild-<UTC>.summary.txt — 总墙钟 + 串口 [M6 ...] 阶段行。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK="$ROOT/.guest-runs/riscv64-m6"
RESULT="$WORK/results.txt"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SUMMARY="$WORK/bench-selfbuild-${STAMP}.summary.txt"
LOG="$WORK/bench-selfbuild-${STAMP}.log"

export M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-28800}"
export M6_QEMU_MEM="${M6_QEMU_MEM:-8G}"
export M6_QEMU_SMP="${M6_QEMU_SMP:-4}"
export M6_RESUME="${M6_RESUME:-0}"
export M6_STALL_SEC="${M6_STALL_SEC:-0}"
export M6_GUEST_HEARTBEAT_SEC="${M6_GUEST_HEARTBEAT_SEC:-120}"
export M6_HOST_HEARTBEAT_SEC="${M6_HOST_HEARTBEAT_SEC:-120}"
export M6_RESUME="${M6_RESUME:-0}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-4}"

mkdir -p "$WORK"
ROOTFS="${ROOTFS:-$ROOT/tests/selfhost/rootfs-selfbuild-riscv64.img}"
export ROOTFS
[[ -f "$ROOTFS" ]] || { echo "ROOTFS not found: $ROOTFS" >&2; exit 1; }

{
    echo "bench_m6_guest_starryos_time stamp=$STAMP"
    echo "ROOTFS=$ROOTFS"
    echo "M6_QEMU_TIMEOUT_SEC=$M6_QEMU_TIMEOUT_SEC M6_QEMU_MEM=$M6_QEMU_MEM M6_QEMU_SMP=$M6_QEMU_SMP"
    echo "CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS RAYON_NUM_THREADS=$RAYON_NUM_THREADS"
    echo "host_wall_start_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$SUMMARY"

T0=$(date +%s)
set +e
bash "$ROOT/scripts/demo-m6-selfbuild.sh" 2>&1 | tee "$LOG"
DEMO_EC=$?
set -e
T1=$(date +%s)
WALL=$((T1 - T0))

{
    echo ""
    echo "===== host wall ====="
    echo "host_wall_total_seconds=$WALL"
    echo "demo_exit_code=$DEMO_EC"
    echo "host_wall_end_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "===== serial markers (strings $RESULT) ====="
    if [[ -f "$RESULT" ]]; then
        strings "$RESULT" 2>/dev/null | grep -E '===M6-SELFBUILD|^(\[M6 |\[2\]|\[3\]|\[4\])' | tail -80 || true
        echo ""
        echo "===== last Compiling / Finished / error (serial) ====="
        strings "$RESULT" 2>/dev/null | grep -iE 'Compiling |Finished |error:|panic:' | tail -40 || true
    else
        echo "(no $RESULT)"
    fi
} | tee -a "$SUMMARY"

# 若 PASS，尝试 loop 挂载看访客产物大小（需 root + loop；失败则跳过）
GELF="/opt/tgoskits/target/riscv64gc-unknown-none-elf/release/starryos"
if grep -q "===M6-SELFBUILD-PASS===" "$RESULT" 2>/dev/null; then
    echo "" | tee -a "$SUMMARY"
    echo "===== guest-built ELF (loop mount) =====" | tee -a "$SUMMARY"
    MNT=/tmp/rfsmnt-m6-bench-verify
    if [[ "$(id -u)" -eq 0 ]]; then
        umount "$MNT" 2>/dev/null || true
        mkdir -p "$MNT"
        if mount -o loop "$ROOTFS" "$MNT" 2>/dev/null; then
            if [[ -f "$MNT$GELF" ]]; then
                ls -lh "$MNT$GELF" | tee -a "$SUMMARY"
                file "$MNT$GELF" 2>/dev/null | head -1 | tee -a "$SUMMARY" || true
            else
                echo "missing $GELF on disk image" | tee -a "$SUMMARY"
            fi
            umount "$MNT" 2>/dev/null || true
        else
            echo "(skip mount: not root or mount failed)" | tee -a "$SUMMARY"
        fi
    else
        echo "(skip mount: run as root to stat guest ELF)" | tee -a "$SUMMARY"
    fi
fi

echo "" | tee -a "$SUMMARY"
echo "Wrote: $SUMMARY" | tee -a "$SUMMARY"
echo "       $LOG" | tee -a "$SUMMARY"

exit "$DEMO_EC"
