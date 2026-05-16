#!/usr/bin/env bash
# 对齐跑宿主 strace 时间桶 + 访客周期性 /proc/syscall_stats，并生成折线图 HTML。
# 用法（仓库根）：
#   bash scripts/run-aligned-metadata-chart.sh
# 依赖：Docker auto-os/starry；访客 rootfs/内核同 guest-cargo-syscall-evidence.sh。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTD="${ROOT}/.guest-runs/guest-cargo-evidence"
mkdir -p "$OUTD"

echo "[1/3] host: strace time buckets -> ${OUTD}/host-metadata-series.json"
docker run --rm -v "${ROOT}:/work" -w /work/tgoskits \
  -e "HOST_STRACE_BUCKET_MS=${HOST_STRACE_BUCKET_MS:-10}" \
  auto-os/starry:latest bash -lc '
  command -v strace >/dev/null || (apt-get update -qq && apt-get install -y -qq strace)
  python3 /work/scripts/host-metadata-strace-series.py \
    --cwd /work/tgoskits \
    --bucket-ms "${HOST_STRACE_BUCKET_MS}" \
    --out /work/.guest-runs/guest-cargo-evidence/host-metadata-series.json
'

echo "[2/3] guest: QEMU serial (with ===SYSCALL_SAMPLE)"
docker run --rm --privileged --network host \
  -v "${ROOT}:/work" -w /work \
  -e GUEST_EVIDENCE_TIMEOUT="${GUEST_EVIDENCE_TIMEOUT:-3600}" \
  -e GUEST_EVIDENCE_SKIP_KERNEL_SAVE=1 \
  auto-os/starry:latest \
  bash /work/scripts/guest-cargo-syscall-evidence.sh

echo "[3/3] plot -> ${OUTD}/aligned-metadata-syscall-chart.html"
python3 "${ROOT}/scripts/plot-aligned-metadata-syscall.py" \
  --guest-log "${OUTD}/results.txt" \
  --host-json "${OUTD}/host-metadata-series.json" \
  --out "${OUTD}/aligned-metadata-syscall-chart.html"

echo "Done. Open:"
echo "  file://${OUTD}/aligned-metadata-syscall-chart.html"
