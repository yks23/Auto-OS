#!/usr/bin/env bash
# m6-selfbuild-watch.sh — 宿主侧轮询串口日志中的 M6 / cargo 阶段行（不依赖 tail -f 的 TTY）。
#
# 用法（仓库根）：
#   bash scripts/m6-selfbuild-watch.sh
#   M6_WATCH_INTERVAL_SEC=30 RESULT=/path/to/results.txt bash scripts/m6-selfbuild-watch.sh
#
# 另：可在第二终端对同一文件执行 tail -f（原始串口含控制字符时可能较乱）：
#   tail -f .guest-runs/riscv64-m6/results.txt
#
# 环境变量：
#   RESULT — 默认 .guest-runs/riscv64-m6/results.txt
#   M6_WATCH_INTERVAL_SEC — 轮询间隔秒数（默认 15）
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULT="${RESULT:-$ROOT/.guest-runs/riscv64-m6/results.txt}"
INTERVAL="${M6_WATCH_INTERVAL_SEC:-15}"

_pat() {
    strings "$1" 2>/dev/null | grep -iE '\[M6 |SELFBUILD|^\s*Compiling |^\s*Finished |^error:|panic' | tail -25 || true
}

echo "[m6-watch] RESULT=$RESULT interval=${INTERVAL}s (Ctrl+C to stop)"
while true; do
    if [[ -f "$RESULT" ]]; then
        bytes=$(wc -c < "$RESULT" 2>/dev/null || echo 0)
        last=$(_pat "$RESULT" | tail -1 || true)
        printf '[m6-watch] %s bytes=%s last_match=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$bytes" "${last:0:200}"
        echo "---"
        _pat "$RESULT"
        echo "---"
    else
        echo "[m6-watch] $(date -u +%Y-%m-%dT%H:%M:%SZ) (waiting for $RESULT)"
    fi
    sleep "$INTERVAL"
done
