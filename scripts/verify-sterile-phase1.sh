#!/usr/bin/env bash
# Sterile Phase 1：**实机全流程** — 必须真实 `docker build`（缺镜像时）、真实跑
# `guest-onecrate-syscall-evidence.sh`（内层 privileged QEMU），禁止依赖上一轮残留的
# `results.txt` 通过 grep。
#
# 无 Docker 或无法 privileged 时直接失败退出（不设“假通过”分支）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="auto-os/starry:latest"
OUTD="${REPO}/.guest-runs/guest-onecrate-bench"
RESULT="${OUTD}/results.txt"
SUMMARY="${OUTD}/summary.txt"

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL: docker 未安装，无法实机验证"
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "FAIL: docker daemon 不可用（试 sudo 或启动 Docker Desktop）"
  exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[+] Missing $IMAGE; building from ${REPO}/Dockerfile（真实 build）"
  docker build -t "$IMAGE" -f "${REPO}/Dockerfile" "$REPO"
fi

mkdir -p "$OUTD"
# 避免读到历史串口文件误判 PASS
rm -f "$RESULT" "$SUMMARY"

export GUEST_ONECRATE_MODE=rustc
export GUEST_ONECRATE_ALLOW_FETCH=0
export GUEST_ONECRATE_SKIP_KERNEL_SAVE=1
export GUEST_ONECRATE_TIMEOUT="${GUEST_ONECRATE_TIMEOUT:-1200}"

cd "$REPO"
set +e
bash scripts/guest-onecrate-syscall-evidence.sh
EV=$?
set -e

if [[ "$EV" -ne 0 ]]; then
  echo "FAIL phase1: guest-onecrate-syscall-evidence.sh exit=$EV"
  exit "$EV"
fi

if [[ ! -s "$RESULT" ]]; then
  echo "FAIL phase1: empty serial log ${RESULT}"
  exit 1
fi

if grep -a -q '===GUEST_ONECRATE_CHECK_RC 0===' "$RESULT"; then
  echo "PASS phase1  image=${IMAGE}  result=${RESULT}"
  exit 0
fi

echo "FAIL phase1  image=${IMAGE}  result=${RESULT}  (missing ===GUEST_ONECRATE_CHECK_RC 0===)"
exit 1
