#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/Users/txc/code/Auto-OS}"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/sbin:/usr/sbin:/sbin:${PATH:-}"

TGOS_REPO="${TGOS_REPO:-$ROOT/tgoskits}"
WORKTREE="${WORKTREE:-$ROOT/.harness-worktrees/tgoskits-dev-sync}"
SYNC_BRANCH="${SYNC_BRANCH:-sync/dev-live}"
CANONICAL_REMOTE="${CANONICAL_REMOTE:-upstream}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
BASE_REF="${BASE_REF:-$CANONICAL_REMOTE/dev}"
DEV_BRANCH="${DEV_BRANCH:-dev}"
MERGE_INTO_DEV="${MERGE_INTO_DEV:-0}"

LOG_DIR="$ROOT/automations/dev-sync/logs"
mkdir -p "$LOG_DIR" "$(dirname "$WORKTREE")"
LOG_FILE="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date '+%F %T')] start dev-sync"
echo "repo=$TGOS_REPO"
echo "baseline=$BASE_REF sync_branch=$SYNC_BRANCH worktree=$WORKTREE"

if [[ ! -d "$TGOS_REPO/.git" && ! -f "$TGOS_REPO/.git" ]]; then
  echo "TGOS_REPO is not a git repo: $TGOS_REPO" >&2
  exit 1
fi

git -C "$TGOS_REPO" fetch "$CANONICAL_REMOTE" dev
git -C "$TGOS_REPO" fetch "$FORK_REMOTE" dev || true

if [[ ! -e "$WORKTREE/.git" ]]; then
  git -C "$TGOS_REPO" worktree add -B "$SYNC_BRANCH" "$WORKTREE" "$BASE_REF"
fi

git -C "$WORKTREE" checkout "$SYNC_BRANCH"
git -C "$WORKTREE" fetch "$CANONICAL_REMOTE" dev
git -C "$WORKTREE" reset --hard "$BASE_REF"

echo "sync branch at $(git -C "$WORKTREE" rev-parse --short HEAD)"
git -C "$WORKTREE" push "$FORK_REMOTE" "$SYNC_BRANCH"

if [[ "$MERGE_INTO_DEV" == "1" ]]; then
  echo "merge $SYNC_BRANCH into $DEV_BRANCH"
  DEV_WORKTREE="${DEV_WORKTREE:-$ROOT/.harness-worktrees/tgoskits-dev-merge}"
  if [[ ! -e "$DEV_WORKTREE/.git" ]]; then
    git -C "$TGOS_REPO" worktree add -B "$DEV_BRANCH" "$DEV_WORKTREE" "$FORK_REMOTE/$DEV_BRANCH"
  fi
  git -C "$DEV_WORKTREE" checkout "$DEV_BRANCH"
  git -C "$DEV_WORKTREE" fetch "$FORK_REMOTE" "$DEV_BRANCH"
  git -C "$DEV_WORKTREE" pull --ff-only "$FORK_REMOTE" "$DEV_BRANCH"
  git -C "$DEV_WORKTREE" merge --no-edit "$SYNC_BRANCH"
  git -C "$DEV_WORKTREE" push "$FORK_REMOTE" "$DEV_BRANCH"
fi

echo "[$(date '+%F %T')] done dev-sync"
