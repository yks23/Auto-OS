#!/usr/bin/env bash
# 单 crate（默认 ax-errno）宿主 strace 桶 + 访客 /proc/syscall_stats 采样 → 折线图 + 限时。
#
# 环境变量（可选）：
#   HOST_ONECRATE_TIMEOUT_SEC   默认 600  — 包住 strace+cargo（timeout 124=杀进程）
#   HOST_STRACE_BUCKET_MS         默认 20
#   GUEST_ONECRATE_TIMEOUT        默认 7200 — QEMU 整段
#   GUEST_ONECRATE_SAMPLE_SLEEP   默认 0.5 — 访客采样间隔（秒）
#   GUEST_ONECRATE_SKIP_KERNEL_SAVE 默认 1
#   GUEST_ONECRATE_MODE           默认 cargo（与宿主对齐）；设 rustc 则访客只 rustc hello.rs，无网络/cargo
#   GUEST_ONECRATE_ALLOW_FETCH    默认 0 — 不 cargo fetch；=1 才允许联网 prefetch
#   GUEST_ONECRATE_PROGRESS_SEC   默认 300 — 访客串口「仍在编译」心跳间隔（秒），0=关闭
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTD="${ROOT}/.guest-runs/guest-onecrate-bench"
mkdir -p "$OUTD"
# 若从外部 `bash 本脚本 | tee $OUTD/log`，tee 会在 mkdir 之前打开文件；此处统一在目录就绪后 tee 全量输出。
exec > >(tee -a "${OUTD}/run-onecrate-chart.log") 2>&1

H_TO="${HOST_ONECRATE_TIMEOUT_SEC:-600}"
B_MS="${HOST_STRACE_BUCKET_MS:-20}"
G_TO="${GUEST_ONECRATE_TIMEOUT:-7200}"

echo "[1/3] host: prefetch (online) + timeout ${H_TO}s + strace buckets -> ${OUTD}/host-onecrate-series.json"
docker run --rm -v "${ROOT}:/work" -w /work/tgoskits \
  -e "HOST_STRACE_BUCKET_MS=${B_MS}" \
  -e "HOST_ONECRATE_TIMEOUT_SEC=${H_TO}" \
  auto-os/starry:latest bash -lc '
  command -v strace >/dev/null || (apt-get update -qq && apt-get install -y -qq strace)
  # 干净容器无 registry 缓存时 --offline 会失败；先拉依赖再离线 check。
  cargo fetch --target riscv64gc-unknown-none-elf
  python3 /work/scripts/host-onecrate-strace-series.py \
    --cwd /work/tgoskits \
    --crate ax-errno \
    --target riscv64gc-unknown-none-elf \
    --bucket-ms "$HOST_STRACE_BUCKET_MS" \
    --timeout-sec "$HOST_ONECRATE_TIMEOUT_SEC" \
    --out /work/.guest-runs/guest-onecrate-bench/host-onecrate-series.json
'

echo "[2/3] guest: QEMU (timeout ${G_TO}s) …"
# 与 guest-onecrate-syscall-evidence.sh 一致：避免宿主 `set -u` 或未传 -e 时容器内展开异常。
export GUEST_ONECRATE_MODE="${GUEST_ONECRATE_MODE:-cargo}"
export GUEST_ONECRATE_ALLOW_FETCH="${GUEST_ONECRATE_ALLOW_FETCH:-0}"
docker run --rm --privileged --network host \
  -v "${ROOT}:/work" -w /work \
  -e "GUEST_ONECRATE_TIMEOUT=${G_TO}" \
  -e "GUEST_ONECRATE_SKIP_KERNEL_SAVE=${GUEST_ONECRATE_SKIP_KERNEL_SAVE:-1}" \
  -e "GUEST_ONECRATE_SAMPLE_SLEEP=${GUEST_ONECRATE_SAMPLE_SLEEP:-0.5}" \
  -e "GUEST_ONECRATE_MODE=${GUEST_ONECRATE_MODE:-cargo}" \
  -e "GUEST_ONECRATE_ALLOW_FETCH=${GUEST_ONECRATE_ALLOW_FETCH:-0}" \
  -e "GUEST_ONECRATE_PROGRESS_SEC=${GUEST_ONECRATE_PROGRESS_SEC:-300}" \
  auto-os/starry:latest \
  bash /work/scripts/guest-onecrate-syscall-evidence.sh

echo "[3/3] plot -> ${OUTD}/aligned-onecrate-syscall-chart.html"
python3 "${ROOT}/scripts/plot-aligned-onecrate-syscall.py" \
  --guest-log "${OUTD}/results.txt" \
  --guest-summary "${OUTD}/summary.txt" \
  --host-json "${OUTD}/host-onecrate-series.json" \
  --out "${OUTD}/aligned-onecrate-syscall-chart.html"

echo "Done."
echo "  file://${OUTD}/aligned-onecrate-syscall-chart.html"
echo "  summary: ${OUTD}/summary.txt"
