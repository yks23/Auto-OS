#!/usr/bin/env bash
# 等待指定 subagent 写完 sentinel 文件就立即返回。
#
# 用法：
#   scripts/wait-for-done.sh F-alpha F-beta             # 等任意一个完成就 print 它
#   scripts/wait-for-done.sh --all F-alpha F-beta       # 等全部完成
#   scripts/wait-for-done.sh --timeout 7200 F-alpha     # 自定义超时（秒）
#
# Sentinel 约定：subagent 完成时必须 touch selfhost-orchestrator/done/<task>.done
# 文件内容是 final JSON summary。Director 看到文件出现就立即 review。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONE="$ROOT/selfhost-orchestrator/done"
mkdir -p "$DONE"

WAIT_ALL=0
TIMEOUT=14400  # 默认 4 小时
TASKS=()
for arg in "$@"; do
    case "$arg" in
        --all) WAIT_ALL=1 ;;
        --timeout) shift; TIMEOUT="$1" ;;
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        --help|-h)
            grep -E '^# ' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) TASKS+=("$arg") ;;
    esac
done

if (( ${#TASKS[@]} == 0 )); then
    echo "ERROR: no tasks specified" >&2
    exit 1
fi

echo "[wait-for-done] watching: ${TASKS[*]} (timeout=${TIMEOUT}s, wait_all=$WAIT_ALL)" >&2
START=$(date +%s)

while true; do
    finished=()
    for t in "${TASKS[@]}"; do
        f="$DONE/$t.done"
        if [[ -f "$f" ]]; then
            finished+=("$t")
        fi
    done

    if (( WAIT_ALL )); then
        if (( ${#finished[@]} == ${#TASKS[@]} )); then
            echo "[wait-for-done] all ${#TASKS[@]} tasks done" >&2
            for t in "${TASKS[@]}"; do
                echo "===== $t ====="
                cat "$DONE/$t.done"
                echo
            done
            exit 0
        fi
    else
        if (( ${#finished[@]} > 0 )); then
            echo "[wait-for-done] finished: ${finished[*]}" >&2
            for t in "${finished[@]}"; do
                echo "===== $t ====="
                cat "$DONE/$t.done"
                echo
            done
            exit 0
        fi
    fi

    NOW=$(date +%s)
    if (( NOW - START > TIMEOUT )); then
        echo "[wait-for-done] TIMEOUT after ${TIMEOUT}s; finished so far: ${finished[*]:-none}" >&2
        for t in "${finished[@]:-}"; do
            [[ -z "$t" ]] && continue
            echo "===== $t ====="
            cat "$DONE/$t.done"
            echo
        done
        exit 124
    fi

    sleep 30
done
