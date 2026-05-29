#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/txc/code/Auto-OS"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/sbin:/usr/sbin:/sbin:${PATH:-}"
TGOS_REPO="${TGOS_REPO:-$ROOT/tgoskits}"
STATE_DIR="$ROOT/automations/pr-healer/state"
LOG_DIR="$ROOT/automations/pr-healer/logs"
SUCCESS_DIR="$ROOT/success-pr"
CONFIG_FILE="$ROOT/automations/pr-healer/config.env"
REPO="rcore-os/tgoskits"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$SUCCESS_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/run-$TS.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%F %T')] start pr-healer"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

: "${AUTO_FIX_CMD:=}"
: "${GH_REPO:=$REPO}"
: "${PR_HEALER_WORK_BASE:=$ROOT/.harness-worktrees/pr-healer}"

GH_BIN="${GH_BIN:-$(command -v gh || true)}"
JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"

if [[ -z "$GH_BIN" || ! -x "$GH_BIN" ]]; then
  echo "gh not found; PATH=$PATH"; exit 1
fi

if [[ -z "$JQ_BIN" || ! -x "$JQ_BIN" ]]; then
  echo "jq not found; PATH=$PATH"; exit 1
fi

if [[ ! -d "$TGOS_REPO/.git" && ! -f "$TGOS_REPO/.git" ]]; then
  echo "TGOS_REPO is not a git repo: $TGOS_REPO"; exit 1
fi

# 获取当前用户
ME="$("$GH_BIN" api user -q .login)"
echo "github user: $ME"
echo "tgos repo: $TGOS_REPO"

# 拉取 open PR（作者是自己）
PRS_JSON="$("$GH_BIN" pr list -R "$GH_REPO" --state open --author "$ME" --json number,title,headRefName,url)"

if [[ "$(echo "$PRS_JSON" | "$JQ_BIN" 'length')" -eq 0 ]]; then
  echo "no open PR by $ME"
fi

handle_pr() {
  local num="$1" head="$2" title="$3" url="$4"
  echo "---- PR #$num $title ($head) ----"

  # 检查是否有非成功 check
  local checks
  checks="$("$GH_BIN" pr checks -R "$GH_REPO" "$num" --json name,state,link 2>/dev/null || true)"

  if [[ -z "$checks" || "$checks" == "[]" ]]; then
    echo "no checks info, skip"
    return 0
  fi

  local failing_count
  failing_count="$(echo "$checks" | "$JQ_BIN" '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED")] | length')"

  if [[ "$failing_count" -eq 0 ]]; then
    echo "checks all green"
    return 0
  fi

  echo "non-green checks: $failing_count"
  echo "$checks" | "$JQ_BIN" -r '.[] | "- \(.name): \(.state) \(.link // "")"'

  if [[ -z "$AUTO_FIX_CMD" ]]; then
    echo "AUTO_FIX_CMD is empty, skip auto-fix"
    return 0
  fi

  local worktree="$PR_HEALER_WORK_BASE/pr-$num"
  mkdir -p "$PR_HEALER_WORK_BASE"

  git -C "$TGOS_REPO" fetch origin "$head"
  if [[ ! -e "$worktree/.git" ]]; then
    git -C "$TGOS_REPO" worktree add -B "$head" "$worktree" "origin/$head"
  fi
  git -C "$worktree" checkout "$head"
  git -C "$worktree" reset --hard "origin/$head"

  local before_sha
  before_sha="$(git -C "$worktree" rev-parse HEAD)"

  echo "run AUTO_FIX_CMD..."
  (cd "$worktree" && bash -lc "$AUTO_FIX_CMD")

  # 仅当有变更时提交
  if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
    git -C "$worktree" add -A
    git -C "$worktree" commit -m "chore(ci): auto-fix PR #$num failing checks"
    git -C "$worktree" push origin "$head"
    echo "pushed fixes to $head"
  else
    echo "no file changes produced by AUTO_FIX_CMD"
  fi

  local after_sha
  after_sha="$(git -C "$worktree" rev-parse HEAD)"

  if [[ "$before_sha" == "$after_sha" ]]; then
    echo "no new commit on PR #$num"
  else
    echo "new commit: $before_sha -> $after_sha"
  fi
}

# shellcheck disable=SC2016
echo "$PRS_JSON" | "$JQ_BIN" -r '.[] | @sh "\(.number)\t\(.headRefName)\t\(.title)\t\(.url)"' | while IFS=$'\t' read -r num head title url; do
  eval "num=$num; head=$head; title=$title; url=$url"
  handle_pr "$num" "$head" "$title" "$url"
done

# 归档：如果 PR 已关闭且 merged，就落盘到 /success-pr
echo "check merged PRs for archive"
"$GH_BIN" pr list -R "$GH_REPO" --state merged --author "$ME" --limit 100 --json number,title,mergedAt,url | \
  "$JQ_BIN" -r '.[] | "\(.number)\t\(.title)\t\(.mergedAt)\t\(.url)"' | \
  while IFS=$'\t' read -r n t m u; do
    out="$SUCCESS_DIR/pr-$n.txt"
    if [[ ! -f "$out" ]]; then
      {
        echo "PR #$n"
        echo "title: $t"
        echo "mergedAt: $m"
        echo "url: $u"
        echo "archivedAt: $(date -u +%FT%TZ)"
      } > "$out"
      echo "archived merged PR #$n -> $out"
    fi
  done

echo "[$(date '+%F %T')] done"
