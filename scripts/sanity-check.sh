#!/usr/bin/env bash
# 健康检查：
#   - tgoskits 在 PIN commit
#   - 所有 patch apply 干净
#   - 各任务的 patch 互相无冲突
#   - tgoskits 文件树不脏
#
# 用法：scripts/sanity-check.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

reset_to_pin

errors=0

# 1. 单独 apply 每个任务，验证 patch 自身有效
for d in $(list_patch_dirs); do
    name="$(basename "$d")"
    patches=()
    while IFS= read -r p; do patches+=("$p"); done < <(list_patches_in "$d")
    if (( ${#patches[@]} == 0 )); then
        log "skip $name (empty)"
        continue
    fi
    log "test apply: $name"
    reset_to_pin
    if ! (cd "$TGOSKITS" && git am --3way --keep-cr "${patches[@]}" >/dev/null 2>&1); then
        log "  ✗ $name: standalone apply failed"
        (cd "$TGOSKITS" && git am --abort 2>/dev/null || true)
        ((errors++))
    else
        log "  ✓ $name: apply ok"
    fi
done

# 2. 全部 apply 一次（验证两两不冲突）
reset_to_pin
log "test apply: ALL patches together"
all=()
for d in $(list_patch_dirs); do
    while IFS= read -r p; do all+=("$p"); done < <(list_patches_in "$d")
done
if (( ${#all[@]} > 0 )); then
    if ! (cd "$TGOSKITS" && git am --3way --keep-cr "${all[@]}" >/dev/null 2>&1); then
        log "  ✗ combined apply FAILED — patches conflict with each other"
        (cd "$TGOSKITS" && git am --abort 2>/dev/null || true)
        ((errors++))
    else
        log "  ✓ combined apply ok"
    fi
else
    log "  (no patches yet)"
fi

# 3. 重置工作树
reset_to_pin

if (( errors > 0 )); then
    log "FAIL: $errors sanity errors"
    exit 1
fi
log "OK: all $(( $(list_patch_dirs | wc -l) )) patch sets sane"
