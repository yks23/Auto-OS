#!/usr/bin/env bash
# 实时查看 M6 宿主进度（与 demo-m6-selfbuild.sh 写入的 m6-progress.log 配套）。
#
# 用法：
#   bash scripts/m6-watch-progress.sh
#   M6_WORK=.guest-runs/riscv64-m6 bash scripts/m6-watch-progress.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${M6_WORK:-$ROOT/.guest-runs/riscv64-m6}"
LOG="${M6_PROGRESS_LOG:-$WORK/m6-progress.log}"
if [[ ! -f "$LOG" ]]; then
    echo "no log yet: $LOG (start demo-m6-selfbuild.sh first)" >&2
    exit 1
fi
echo "==> tail -f $LOG  (Ctrl+C to stop)"
tail -f "$LOG"
