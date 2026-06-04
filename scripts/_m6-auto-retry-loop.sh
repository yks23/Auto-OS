#!/bin/bash
# Auto-retry M6 selfbuild: e2fsck + restore scripts + restart
# Loops until build succeeds (PASS) or max retries reached
set -e

MAX_RETRIES=${1:-20}
ROOTFS=".guest-runs/rootfs-selfbuild-riscv64.img"
LOG="/tmp/m6-auto-retry.log"
SCRIPT="/work/scripts/_guest-build-starry-kernel.sh"
REPO_SCRIPT="/work/scripts/_guest-build-starry-kernel.sh"

echo "=== M6 Auto-Retry Loop (max $MAX_RETRIES) ===" | tee -a "$LOG"

for i in $(seq 1 $MAX_RETRIES); do
    echo "$(date): === Run $i/$MAX_RETRIES ===" | tee -a "$LOG"

    # e2fsck
    e2fsck -fy "$ROOTFS" 2>&1 | tail -1 | tee -a "$LOG"

    # Mount, restore scripts, clean target if needed
    mkdir -p /tmp/rfsmnt
    mount -o loop "$ROOTFS" /tmp/rfsmnt

    # Restore build-starry-kernel.sh from repo
    cp "$REPO_SCRIPT" /tmp/rfsmnt/opt/build-starry-kernel.sh
    chmod +x /tmp/rfsmnt/opt/build-starry-kernel.sh

    # Verify .axconfig.toml has task-stack-size
    if ! grep -q "task-stack-size" /tmp/rfsmnt/opt/tgoskits/os/StarryOS/.axconfig.toml 2>/dev/null; then
        cp /work/tgoskits/os/StarryOS/.axconfig.toml /tmp/rfsmnt/opt/tgoskits/os/StarryOS/.axconfig.toml
        echo "$(date): restored .axconfig.toml" | tee -a "$LOG"
    fi

    # Check disk space
    AVAIL=$(df /tmp/rfsmnt | tail -1 | awk '{print $4}')
    echo "$(date): disk avail=${AVAIL}K" | tee -a "$LOG"

    umount /tmp/rfsmnt

    # Run build
    RUN_LOG="/tmp/m6-run-${i}.log"
    echo "$(date): starting QEMU (log: $RUN_LOG)" | tee -a "$LOG"

    ROOTFS="$ROOTFS" M6_QEMU_TIMEOUT_SEC=28800 CARGO_BUILD_JOBS=1 RAYON_NUM_THREADS=1 \
        bash /work/scripts/demo-m6-selfbuild.sh 2>&1 | tee "$RUN_LOG"

    # Check result
    if grep -q "===M6-SELFBUILD-PASS===" "$RUN_LOG" 2>/dev/null || \
       grep -q "===M6-SELFBUILD-KERNEL-LIB-PASS===" "$RUN_LOG" 2>/dev/null; then
        echo "$(date): RUN $i PASSED!" | tee -a "$LOG"
        exit 0
    fi

    # Count crates compiled
    CRATES=$(grep -ac "Compiling" "$RUN_LOG" 2>/dev/null || echo 0)
    ELAPSED=$(grep -a "QEMU finished after" "$RUN_LOG" 2>/dev/null | grep -o '[0-9]*s' | head -1)
    echo "$(date): run $i failed after ${ELAPSED:-?}, compiled ~${CRATES} crates" | tee -a "$LOG"

    # If kernel panic at file.rs, just retry
    if grep -q "panicked at.*file.rs:705" "$RUN_LOG" 2>/dev/null; then
        echo "$(date): kernel panic (rsext4 I/O) — retrying" | tee -a "$LOG"
    elif grep -q "No space left on device" "$RUN_LOG" 2>/dev/null; then
        echo "$(date): ENOSPC (kernel bug) — retrying" | tee -a "$LOG"
    else
        echo "$(date): unexpected failure — check $RUN_LOG" | tee -a "$LOG"
        # Don't auto-retry on unexpected errors
        exit 1
    fi

    # Clean target if corrupted
    mount -o loop "$ROOTFS" /tmp/rfsmnt 2>/dev/null || true
    if mountpoint -q /tmp/rfsmnt; then
        # Only clean fingerprints/deps — keep rlib for incremental
        rm -rf /tmp/rfsmnt/opt/tgoskits/target/*/.fingerprint 2>/dev/null || true
        rm -rf /tmp/rfsmnt/opt/tgoskits/target/*/build 2>/dev/null || true
        umount /tmp/rfsmnt
    fi

    sleep 2
done

echo "$(date): exhausted $MAX_RETRIES retries" | tee -a "$LOG"
exit 1
