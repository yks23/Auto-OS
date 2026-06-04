#!/usr/bin/env bash
# 宿主侧：连续跑 cargo-hello 的最短反馈链（check -> build -> run），每步独立超时。
# 用于缩短「改代码 -> 验证」闭环；全部通过后再跑长 onecrate / ax-errno。
#
# 用法（在仓库根，非 root，会进 Docker）：
#   bash scripts/guest-onecrate-quick-matrix.sh
#
# 环境变量（可选，透传给 guest-onecrate-syscall-evidence.sh）：
#   GUEST_ONECRATE_SKIP_DOCKER_PREFLIGHT  DOCKER_PLATFORM  DOCKER_STARRY_IMAGE
#   GUEST_ONECRATE_CHECK_TIMEOUT   默认 180
#   GUEST_ONECRATE_BUILD_TIMEOUT   默认 300
#   GUEST_ONECRATE_RUN_TIMEOUT     默认 420
#   GUEST_ONECRATE_DISPOSABLE_ROOTFS  默认 0（避免每轮复制大 rootfs）
#   GUEST_ONECRATE_SKIP_STATS_RESET   默认 1
#   GUEST_ONECRATE_TAIL_HTTP       默认 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/inc/docker-starry.inc.sh"

CHK_TO="${GUEST_ONECRATE_CHECK_TIMEOUT:-180}"
BLD_TO="${GUEST_ONECRATE_BUILD_TIMEOUT:-300}"
RUN_TO="${GUEST_ONECRATE_RUN_TIMEOUT:-420}"

_run_one() {
  local phase="$1" to="$2" tag="$3"
  local out="${REPO}/.guest-runs/quick-matrix-${tag}-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${out}"
  echo "=== quick-matrix ${tag} phase=${phase} timeout=${to}s out=${out} ===" >&2
  (
    cd "${REPO}"
    GUEST_ONECRATE_OUT_DIR="/work/.guest-runs/quick-matrix-${tag}-latest" \
      GUEST_ONECRATE_RESULTS="/work/.guest-runs/quick-matrix-${tag}-latest/results.txt" \
      GUEST_ONECRATE_SUMMARY="/work/.guest-runs/quick-matrix-${tag}-latest/summary.txt" \
      GUEST_ONECRATE_MODE=cargo-hello \
      GUEST_ONECRATE_CARGO_PHASE="${phase}" \
      GUEST_ONECRATE_TIMEOUT="${to}" \
      GUEST_ONECRATE_ALLOW_FETCH=0 \
      GUEST_ONECRATE_DISPOSABLE_ROOTFS="${GUEST_ONECRATE_DISPOSABLE_ROOTFS:-0}" \
      GUEST_ONECRATE_TAIL_HTTP="${GUEST_ONECRATE_TAIL_HTTP:-0}" \
      GUEST_ONECRATE_SKIP_STATS_RESET="${GUEST_ONECRATE_SKIP_STATS_RESET:-1}" \
      GUEST_ONECRATE_SYSCALL_STATS_SEC="${GUEST_ONECRATE_SYSCALL_STATS_SEC:-0}" \
      GUEST_ONECRATE_TRACE_SNAPSHOT_SEC="${GUEST_ONECRATE_TRACE_SNAPSHOT_SEC:-0}" \
      GUEST_ONECRATE_DEEP_TRACE_SEC="${GUEST_ONECRATE_DEEP_TRACE_SEC:-0}" \
      bash "${SCRIPT_DIR}/guest-onecrate-syscall-evidence.sh"
  ) >"${out}/host.log" 2>&1 || {
    local ec=$?
    echo "[quick-matrix] FAIL ${tag} exit=${ec} log=${out}/host.log" >&2
    tail -40 "${out}/host.log" >&2 || true
    return "${ec}"
  }
  echo "[quick-matrix] OK ${tag} log=${out}/host.log" >&2
}

# On macOS, use native QEMU instead of Docker (avoids Docker Desktop runc issues)
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "[quick-matrix] macOS detected — using native QEMU path (no Docker)" >&2
  export GUEST_ONECRATE_MACOS_NATIVE=1
  export GUEST_ONECRATE_SKIP_INJECT=1  # rootfs should already have scripts
else
  docker_starry_preflight
fi

_run_one hello-check "${CHK_TO}" check
_run_one hello-build "${BLD_TO}" build
_run_one hello-run "${RUN_TO}" run

echo "=== quick-matrix ALL OK ===" >&2
