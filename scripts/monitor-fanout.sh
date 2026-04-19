#!/usr/bin/env bash
# 实时监控 5 个 subagent 进度。
#
# 用法：
#   scripts/monitor-fanout.sh             # 一次性快照
#   watch -n 5 scripts/monitor-fanout.sh  # 每 5 秒刷新
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="$ROOT/selfhost-orchestrator/logs"

echo "==================== Subagent Fan-out Status ===================="
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo ""

for tid in T1 T2 T3 T4 T5; do
    log=$(ls -t "$LOGS"/${tid}_*.log 2>/dev/null | head -1 || true)
    if [[ -z "$log" ]]; then
        printf "[%s] no log yet\n" "$tid"
        continue
    fi

    # PID
    pid=$(head -3 "$log" | grep -oP '(?<=pid=)\d+' || echo "-")
    # 看 process 还活着吗（grep dispatch 里的 cursor-agent 进程）
    alive="?"
    if pgrep -f "cursor-agent" >/dev/null; then
        # 简单按 worktree 路径找
        if pgrep -f "/workspace/.worktrees/${tid}" >/dev/null 2>&1; then
            alive="LIVE"
        else
            alive="done"
        fi
    fi

    bytes=$(stat -c %s "$log")
    last_event=$(tail -c 4096 "$log" | grep -oE '"type":"[^"]+"' | tail -1 | sed 's/"type":"//;s/"$//' || echo "-")
    last_text=$(tail -c 8192 "$log" | grep -oE '"text":"[^"]{0,80}' | tail -1 | sed 's/"text":"//' | tr -d '\\' || echo "-")

    # 是否已写入 result subtype
    if grep -q '"type":"result"' "$log" 2>/dev/null; then
        finished="✅FIN"
    else
        finished="⏳"
    fi

    printf "[%s] %-6s %s log=%dKB last_event=%s\n" \
        "$tid" "$alive" "$finished" $((bytes/1024)) "$last_event"
    if [[ -n "$last_text" && "$last_text" != "-" ]]; then
        printf "       last text: %s\n" "$last_text"
    fi
done

echo ""
echo "=== Branches pushed to origin ==="
for tid in T1 T2 T3 T4 T5; do
    case "$tid" in
        T1) br=cursor/selfhost-execve-mt-7c9d ;;
        T2) br=cursor/selfhost-file-locks-7c9d ;;
        T3) br=cursor/selfhost-ipv6-7c9d ;;
        T4) br=cursor/selfhost-mount-fs-7c9d ;;
        T5) br=cursor/selfhost-resource-limits-7c9d ;;
    esac
    if git -C "$ROOT" ls-remote origin "refs/heads/$br" 2>/dev/null | grep -q .; then
        sha=$(git -C "$ROOT" ls-remote origin "refs/heads/$br" | awk '{print $1}' | head -c 12)
        echo "[$tid] pushed: $br ($sha)"
    else
        echo "[$tid] not pushed yet: $br"
    fi
done
