#!/usr/bin/env bash
# 等待指定 subagent 写完 sentinel 文件就立即返回。
# 如果 subagent 进程死了但没写 sentinel：自动用 dispatcher --resume 让它补写。
#
# 用法：
#   scripts/wait-for-done.sh F-alpha F-beta             # 等任意一个完成就 print 它
#   scripts/wait-for-done.sh --all F-alpha F-beta       # 等全部完成
#   scripts/wait-for-done.sh --timeout 7200 F-alpha     # 自定义超时（秒）
#   scripts/wait-for-done.sh --no-auto-resume ...       # 关闭自动补 sentinel
#
# Sentinel 约定：subagent 完成时必须写
#   selfhost-orchestrator/done/<task>.done   (内容 = final JSON summary)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DONE="$ROOT/selfhost-orchestrator/done"
SESSIONS="$ROOT/selfhost-orchestrator/sessions"
LOGS="$ROOT/selfhost-orchestrator/logs"
mkdir -p "$DONE"

WAIT_ALL=0
TIMEOUT=14400  # 默认 4 小时
AUTO_RESUME=1
TASKS=()
while (( $# > 0 )); do
    case "$1" in
        --all) WAIT_ALL=1 ;;
        --timeout) shift; TIMEOUT="$1" ;;
        --timeout=*) TIMEOUT="${1#--timeout=}" ;;
        --no-auto-resume) AUTO_RESUME=0 ;;
        --help|-h) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
        *) TASKS+=("$1") ;;
    esac
    shift
done

(( ${#TASKS[@]} > 0 )) || { echo "ERROR: no tasks" >&2; exit 1; }

echo "[wait-for-done] watching: ${TASKS[*]} (timeout=${TIMEOUT}s wait_all=$WAIT_ALL auto_resume=$AUTO_RESUME)" >&2
START=$(date +%s)
declare -A AUTO_RESUMED  # 已经为某 task 触发过自动 resume

is_subagent_alive() {
    local task="$1"
    # 找 cursor-agent 进程包含这个 task 的 worktree 路径
    pgrep -f "cursor-agent.*--workspace.*\.worktrees/$task" >/dev/null
}

trigger_resume() {
    local task="$1"
    [[ -n "${AUTO_RESUMED[$task]:-}" ]] && return
    AUTO_RESUMED[$task]=1
    echo "[wait-for-done] $task: subagent died without sentinel; auto-resuming with reminder" >&2
    local sid_file="$SESSIONS/$task.session"
    if [[ ! -f "$sid_file" ]]; then
        echo "[wait-for-done] $task: no session id file at $sid_file; cannot resume" >&2
        return
    fi
    local prompt="你之前的工作被截断了（cursor-agent CLI 退出，可能 token cap 或网络）。现在请只做一件事：

1. 评估你之前做到哪一步了
2. 写 sentinel 文件 selfhost-orchestrator/done/$task.done，内容是 final JSON summary，必须包含：
   - task_id: \"$task\"
   - status: \"PASS\" | \"PARTIAL\" | \"FAIL\" | \"BLOCKED\"
   - what_done: 已完成的事情清单
   - what_not_done: 未完成的清单 + 原因
   - blockers: 阻塞项
   - patches: 已生成的 patch 文件列表
   - guest_verified: true|false（是否真在 QEMU 里验证过）

3. 写完 sentinel 后 git add patches/ tests/ docs/ selfhost-orchestrator/done/$task.done
4. git commit + git push origin <你的分支>
5. 输出最终 JSON

不要重新尝试主任务，只补 sentinel + git push。"

    nohup python3 "$ROOT/selfhost-orchestrator/dispatcher.py" \
        --execute --only "$task" --base selfhost-dev --model auto \
        --resume --followup "$prompt" \
        > "$LOGS/${task}_resume_$(date +%s).log" 2>&1 &
    disown
    echo "[wait-for-done] $task: resume launched (pid=$!)" >&2
}

while true; do
    finished=()
    for t in "${TASKS[@]}"; do
        f="$DONE/$t.done"
        if [[ -f "$f" ]]; then
            finished+=("$t")
        elif (( AUTO_RESUME )) && ! is_subagent_alive "$t"; then
            trigger_resume "$t"
        fi
    done

    if (( WAIT_ALL )); then
        if (( ${#finished[@]} == ${#TASKS[@]} )); then
            echo "[wait-for-done] ALL DONE: ${TASKS[*]}" >&2
            for t in "${TASKS[@]}"; do
                echo "===== $t ====="
                cat "$DONE/$t.done"
                echo
            done
            exit 0
        fi
    else
        if (( ${#finished[@]} > 0 )); then
            echo "[wait-for-done] DONE: ${finished[*]}" >&2
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
        echo "[wait-for-done] TIMEOUT after ${TIMEOUT}s; finished: ${finished[*]:-none}" >&2
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
