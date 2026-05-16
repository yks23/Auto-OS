#!/usr/bin/env bash
# demo-m6-lite.sh — single entry for a **low-friction** M6 guest check (subset only).
#
# Lite vs full (full = scripts/demo-m6-selfbuild.sh with no --subset):
#   - full: default QEMU smp=4, mem=5G, outer timeout 4200s; guest compiles full starry kernel.
#   - lite: this wrapper runs `--subset` only (metadata + riscv-h + ax-cpu + ax-errno checks)
#     with smp=1, mem=3G, timeout 3600s, and single-job cargo defaults unless you already exported overrides.
#   Running demo-m6-selfbuild.sh directly leaves all full defaults unchanged.
#
# Other quick paths in-repo: verify-starry-guest-smoke.sh (shell smoke); verify-sterile-phase1.sh
# (Docker + one-crate bench, heavier); verify-m6-rootfs.sh (preflight for M6 rootfs).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[demo-m6-lite] subset M6 selfbuild with conservative QEMU / cargo parallelism (unset env only)."
echo "[demo-m6-lite] exec: demo-m6-selfbuild.sh --subset"
export M6_QEMU_SMP="${M6_QEMU_SMP:-1}"
export M6_QEMU_MEM="${M6_QEMU_MEM:-3G}"
export M6_QEMU_TIMEOUT_SEC="${M6_QEMU_TIMEOUT_SEC:-3600}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
export RAYON_NUM_THREADS="${RAYON_NUM_THREADS:-1}"
echo "[demo-m6-lite] M6_QEMU_SMP=$M6_QEMU_SMP M6_QEMU_MEM=$M6_QEMU_MEM M6_QEMU_TIMEOUT_SEC=$M6_QEMU_TIMEOUT_SEC CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS RAYON_NUM_THREADS=$RAYON_NUM_THREADS"

exec "$SCRIPT_DIR/demo-m6-selfbuild.sh" --subset
