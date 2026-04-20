#!/usr/bin/env bash
# 给一个新任务初始化 patches/<task-id>/ 目录与可选的 worktree。
#
# 用法：
#   scripts/new-task.sh T6-ptrace
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TASK="${1:-}"
[[ -n "$TASK" ]] || die "usage: new-task.sh <task-id>"
[[ "$TASK" =~ ^T[0-9]+(-[a-z0-9-]+)?$ ]] || die "task id must be Tn or Tn-slug"

mkdir -p "$PATCHES/$TASK"
cat > "$PATCHES/$TASK/README.md" <<EOF
# $TASK

任务包：see selfhost-orchestrator/tasks/${TASK%%-*}-*.md

## 状态
- [ ] 实现
- [ ] 自检测试通过
- [ ] sanity-check 通过

## 关联
- task package: selfhost-orchestrator/tasks/${TASK%%-*}-*.md
- branch: cursor/selfhost-${TASK,,}-7c9d
EOF

log "created: $PATCHES/$TASK/"
log "next:"
log "  1. cd tgoskits && git checkout -B cursor/selfhost-${TASK,,}-7c9d $PIN_COMMIT"
log "  2. # ... 编辑 / commit ..."
log "  3. cd .. && scripts/extract-patches.sh $TASK"
